%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(ehttpc).

-behaviour(gen_server).

%% APIs
-export([ start_link/3
        , request/3
        , request/4
        , request/5
        , workers/1
        , name/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-define(LOG(Level, Format, Args), logger:Level("ehttpc: " ++ Format, Args)).

-record(state, {
          pool              :: term(),
          id                :: pos_integer(),
          client            :: pid() | undefined,
          mref              :: reference() | undefined,
          host              :: inet:hostname() | inet:ip_address(),
          port              :: inet:port_number(),
          enable_pipelining :: boolean(),
          gun_opts          :: proplists:proplist(),
          gun_state         :: down | up,
          requests          :: map()
         }).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

start_link(Pool, Id, Opts) ->
    gen_server:start_link(?MODULE, [Pool, Id, Opts], []).

request(Pool, Method, Request) ->
    request(Pool, Method, Request, 5000, 3).

request(Pool, Method, Request, Timeout) ->
    request(Pool, Method, Request, Timeout, 3).

request(Pool, Method, Request, Timeout, Retry) when is_atom(Pool) ->
    request(ehttpc_pool:pick_worker(Pool), Method, Request, Timeout, Retry);

request({Pool, N}, Method, Request, Timeout, Retry) when is_atom(Pool) ->
    request(ehttpc_pool:pick_worker(Pool, N), Method, Request, Timeout, Retry);

request(Worker, Method, Request, Timeout, Retry) when is_pid(Worker) ->
    ExpireAt = now_() + Timeout,
    try gen_server:call(Worker, {Method, Request, ExpireAt}, Timeout + 1000) of
        %% gun will reply {gun_down, _Client, _, normal, _KilledStreams, _} message
        %% when connection closed by keepalive
        {error, Reason} when Retry =< 1 ->
            {error, Reason};
        {error, _} ->
            request(Worker, Method, Request, Timeout, Retry - 1);
        Other ->
            Other
    catch
        exit : {timeout, _Details} ->
            {error, timeout}
    end.

workers(Pool) ->
    gproc_pool:active_workers(name(Pool)).

name(Pool) -> {?MODULE, Pool}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Opts]) ->
    process_flag(trap_exit, true),
    State = #state{pool = Pool,
                   id = Id,
                   client = undefined,
                   mref = undefined,
                   host = proplists:get_value(host, Opts),
                   port = proplists:get_value(port, Opts),
                   enable_pipelining = proplists:get_value(enable_pipelining, Opts, false),
                   gun_opts = gun_opts(Opts),
                   gun_state = down,
                   requests = #{}},
    true = gproc_pool:connect_worker(ehttpc:name(Pool), {Pool, Id}),
    {ok, State}.

handle_call(Request = {_, _, _}, From, State = #state{client = undefined, gun_state = down}) ->
    case open(State) of
        {ok, NewState} ->
            handle_call(Request, From, NewState);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(Request = {_, _, ExpireAt}, From, State = #state{client = Client, mref = MRef, gun_state = down}) when is_pid(Client) ->
    case (Timeout = ExpireAt - now_()) > 0 of
        true ->
            case gun:await_up(Client, Timeout, MRef) of
                {ok, _} ->
                    handle_call(Request, From, State#state{gun_state = up});
                {error, timeout} ->
                    {reply, {error, timeout}, State};
                {error, Reason} ->
                    true = erlang:demonitor(MRef, [flush]),
                    {reply, {error, Reason}, State#state{client = undefined, mref = undefined}}
            end;
        false ->
            {noreply, State}
    end;

handle_call({Method, Request, ExpireAt}, From, State = #state{client = Client,
                                                              requests = Requests,
                                                              enable_pipelining = EnablePipelining,
                                                              gun_state = up}) when is_pid(Client) ->
    case (Timeout = ExpireAt - now_()) > 0 of
        true ->
            StreamRef = do_request(Client, Method, Request),
            case EnablePipelining of
                true ->
                    {noreply, State#state{requests = maps:put(StreamRef, {From, ExpireAt, undefined}, Requests)}};
                false ->
                    await_response(StreamRef, ExpireAt, Timeout, State)
            end;
        false ->
            {noreply, State}
    end;

handle_call(Request, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Request]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({gun_response, Client, _StreamRef, _IsFin, _StatusCode, _Headers}, State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
handle_info({gun_response, Client, StreamRef, IsFin, StatusCode, Headers}, State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    Now = now_(),
    case maps:take(StreamRef, Requests) of
        error ->
            ?LOG(error, "Received 'gun_response' message from unknown stream ref: ~p", [StreamRef]),
            {noreply, State};
        {{_, ExpireAt, _}, NRequests} when Now > ExpireAt ->
            cancel_stream(Client, StreamRef),
            {noreply, State#state{requests = NRequests}};
        {{From, ExpireAt, undefined}, NRequests} ->
            case IsFin of
                fin ->
                    gen_server:reply(From, {ok, StatusCode, Headers}),
                    {noreply, State#state{requests = NRequests}};
                nofin ->
                    {noreply, State#state{requests = NRequests#{StreamRef => {From, ExpireAt, {StatusCode, Headers, <<>>}}}}}
            end;
        _ ->
            ?LOG(error, "Received 'gun_response' message does not match the state", []),
            {noreply, State}
    end;

handle_info({gun_data, Client, _StreamRef, _IsFin, _Data}, State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
handle_info({gun_data, Client, StreamRef, IsFin, Data}, State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    Now = now_(),
    case maps:take(StreamRef, Requests) of
        error ->
            ?LOG(error, "Received 'gun_data' message from unknown stream ref: ~p", [StreamRef]),
            {noreply, State};
        {{_, ExpireAt, _}, NRequests} when Now > ExpireAt ->
            cancel_stream(Client, StreamRef),
            {noreply, State#state{requests = NRequests}};
        {{From, ExpireAt, {StatusCode, Headers, Acc}}, NRequests} ->
            case IsFin of
                fin ->
                    gen_server:reply(From, {ok, StatusCode, Headers, <<Acc/binary, Data/binary>>}),
                    {noreply, State#state{requests = NRequests}};
                nofin ->
                    {noreply, State#state{requests = NRequests#{StreamRef => {From, ExpireAt, {StatusCode, Headers, <<Acc/binary, Data/binary>>}}}}}
            end;
        _ ->
            ?LOG(error, "Received 'gun_data' message does not match the state", []),
            {noreply, State}
    end;

handle_info({gun_error, Client, _StreamRef, _Reason}, State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
handle_info({gun_error, Client, StreamRef, Reason}, State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    Now = now_(),
    case maps:take(StreamRef, Requests) of
        error ->
            ?LOG(error, "Received 'gun_error' message from unknown stream ref: ~p~n", [StreamRef]),
            {noreply, State};
        {{_, ExpireAt, _}, NRequests} when Now > ExpireAt ->
            {noreply, State#state{requests = NRequests}};
        {{From, _, _}, NRequests} ->
            gen_server:reply(From, {error, Reason}),
            {noreply, State#state{requests = NRequests}}
    end;

handle_info({gun_up, Client, _}, State = #state{client = Client}) ->
    {noreply, State#state{gun_state = up}};

handle_info({gun_down, Client, _, _Reason, _KilledStreams, _}, State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State#state{gun_state = down, requests = #{}}};
handle_info({gun_down, Client, _, Reason, KilledStreams, _}, State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    Reason =/= normal andalso Reason =/= closed andalso ?LOG(warning, "Received 'gun_down' message with reason: ~p", [Reason]),
    Now = now_(),
    NRequests = lists:foldl(fun(StreamRef, Acc) ->
                                case maps:take(StreamRef, Acc) of
                                    error ->
                                        Acc;
                                    {{_, ExpireAt, _}, NAcc} when Now > ExpireAt ->
                                        NAcc;
                                    {{From, _, _}, NAcc} ->
                                        gen_server:reply(From, {error, Reason}),
                                        NAcc
                                end
                            end, Requests, KilledStreams),
    {noreply, State#state{gun_state = down, requests = NRequests}};

handle_info({'DOWN', MRef, process, Client, Reason}, State = #state{mref = MRef, client = Client, requests = Requests, enable_pipelining = EnablePipelining}) ->
    true = erlang:demonitor(MRef, [flush]),
    case EnablePipelining of
        true ->
            Now = now_(),
            lists:foreach(fun({_, {_, ExpireAt, _}}) when Now > ExpireAt ->
                              ok;
                             ({_, {From, _, _}}) ->
                              gen_server:reply(From, {error, Reason})
                          end, maps:to_list(Requests));
        false ->
            ok
    end,
    case open(State#state{requests = #{}}) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, _Reason} ->
            {noreply, State#state{mref = undefined, client = undefined}}
    end;

handle_info(Info, State) ->
    ?LOG(error, "Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(ehttpc:name(Pool), {Pool, Id}),
    ok.

code_change({down, _Vsn}, {state, Pool, ID, Client, MRef, Host, Port, _, GunOpts, GunState, _}, [no_requests, no_enable_pipelining]) ->
    {ok, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState}};
code_change({down, _Vsn}, {state, Pool, ID, Client, MRef, Host, Port, _, GunOpts, GunState, Requests}, [no_enable_pipelining]) ->
    {ok, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState, Requests}};
code_change(_Vsn, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState}, _Extra) ->
    {ok, {state, Pool, ID, Client, MRef, Host, Port, true, GunOpts, GunState, #{}}};
code_change(_Vsn, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState, Requests}, _Extra) ->
    {ok, {state, Pool, ID, Client, MRef, Host, Port, true, GunOpts, GunState, Requests}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

open(State = #state{host = Host, port = Port, gun_opts = GunOpts}) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} when is_pid(ConnPid) ->
            MRef = monitor(process, ConnPid),
            {ok, State#state{mref = MRef, client = ConnPid}};
        {error, Reason} ->
            {error, Reason}
    end.

gun_opts(Opts) ->
    gun_opts(Opts, #{retry => 5,
                     retry_timeout => 1000,
                     connect_timeout => 5000,
                     %% The keepalive mechanism of gun will send "\r\n" for keepalive,
                     %% which may cause misjudgment by some servers, so we disabled it by default
                     http_opts => #{keepalive => infinity},
                     protocols => [http]}).

gun_opts([], Acc) ->
    Acc;
gun_opts([{retry, Retry} | Opts], Acc) ->
    gun_opts(Opts, Acc#{retry => Retry});
gun_opts([{retry_timeout, RetryTimeout} | Opts], Acc) ->
    gun_opts(Opts, Acc#{retry_timeout => RetryTimeout});
gun_opts([{connect_timeout, ConnectTimeout} | Opts], Acc) ->
    gun_opts(Opts, Acc#{connect_timeout => ConnectTimeout});
gun_opts([{transport, Transport} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport => Transport});
gun_opts([{transport_opts, TransportOpts} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport_opts => TransportOpts});
gun_opts([_ | Opts], Acc) ->
    gun_opts(Opts, Acc).

do_request(Client, get, {Path, Headers}) ->
    gun:get(Client, Path, Headers);
do_request(Client, post, {Path, Headers, Body}) ->
    gun:post(Client, Path, Headers, Body);
do_request(Client, put, {Path, Headers, Body}) ->
    gun:put(Client, Path, Headers, Body);
do_request(Client, delete, {Path, Headers}) ->
    gun:delete(Client, Path, Headers).

cancel_stream(Client, StreamRef) ->
    gun:cancel(Client, StreamRef),
    flush_stream(Client, StreamRef).

flush_stream(Client, StreamRef) ->
    receive
        {gun_response, Client, StreamRef, _, _, _} ->
            flush_stream(Client, StreamRef);
        {gun_data, Client, StreamRef, _, _} ->
            flush_stream(Client, StreamRef);
        {gun_error, Client, StreamRef, _} ->
            flush_stream(Client, StreamRef)
	after 0 ->
		ok
	end.

await_response(StreamRef, ExpireAt, Timeout, State = #state{client = Client})
  when Timeout > 0 ->
    receive
        {gun_response, Client, StreamRef, fin, StatusCode, Headers} ->
           {reply, {ok, StatusCode, Headers}, State};
        {gun_response, Client, StreamRef, nofin, StatusCode, Headers} ->
            await_remaining_response(StreamRef, ExpireAt, State, {StatusCode, Headers, <<>>});
        {gun_error, Client, StreamRef, Reason} ->
            {reply, {error, Reason}, State};
        {gun_down, Client, _, Reason, _KilledStreams, _} ->
            {reply, {error, Reason}, State};
        {'DOWN', MRef, process, Client, Reason} ->
            true = erlang:demonitor(MRef, [flush]),
            NState = case open(State) of
                        {ok, State1} -> State1;
                        {error, _Reason} -> State#state{mref = undefined, client = undefined}
                    end,
            {reply, {error, Reason}, NState}
    after Timeout ->
        cancel_stream(Client, StreamRef),
        {reply, {error, timeout}, State}
    end.

await_remaining_response(StreamRef, ExpireAt, State = #state{client = Client, mref = MRef}, {StatusCode, Headers, Acc}) ->
    case (Timeout = ExpireAt - now_()) > 0 of
        true ->
            receive
                {gun_data, Client, StreamRef, fin, Data} ->
                    {reply, {ok, StatusCode, Headers, <<Acc/binary, Data/binary>>}, State};
                {gun_data, Client, StreamRef, nofin, Data} ->
                    await_remaining_response(StreamRef, ExpireAt, State, {StatusCode, Headers, <<Acc/binary, Data/binary>>});
                {gun_error, Client, StreamRef, Reason} ->
                    {reply, {error, Reason}, State};
                {gun_down, Client, _, Reason, _KilledStreams, _} ->
                    {reply, {error, Reason}, State};
                {'DOWN', MRef, process, Client, Reason} ->
                    true = erlang:demonitor(MRef, [flush]),
                    NState = case open(State) of
                                {ok, State1} -> State1;
                                {error, _Reason} -> State#state{mref = undefined, client = undefined}
                            end,
                    {reply, {error, Reason}, NState}
            after Timeout ->
                cancel_stream(Client, StreamRef),
                {reply, {error, timeout}, State}
            end;
        false ->
            cancel_stream(Client, StreamRef),
            {noreply, State}
    end.

now_() ->
    erlang:system_time(millisecond).
