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

-export_type([
    pool_name/0,
    option/0
 ]).

-define(LOG(Level, Format, Args), logger:Level("ehttpc: " ++ Format, Args)).
-define(REQ_CALL(Method, Req, ExpireAt), {Method, Req, ExpireAt}).
-define(PEND_REQ(From, Req), {From, Req}).
-define(SENT_REQ(StreamRef, ExpireAt, Acc), {StreamRef, ExpireAt, Acc}).
-define(GEN_CALL_REQ(From, Call), {'$gen_call', From, ?REQ_CALL(_, _, _) = Call}).
-define(undef, undefined).

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

-type pool_name() :: atom().
-type option() :: [{atom(), term()}].

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
    try gen_server:call(Worker, ?REQ_CALL(Method, Request, ExpireAt), Timeout + 1000) of
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
                   requests = #{pending => queue:new(), sent => #{},
                                prioritise_latest => proplists:get_bool(prioritise_latest, Opts)}},
    true = gproc_pool:connect_worker(ehttpc:name(Pool), {Pool, Id}),
    {ok, State}.

handle_call(?REQ_CALL(_Method, _Request, _ExpireAt) = Req, From, State0) ->
    State1 = enqueue_req(From, Req, State0),
    State = maybe_shoot(State1),
    {noreply, State};
handle_call(Call, _From, State0) ->
    State = maybe_shoot(State0),
    {reply, {error, {unexpected_call, Call}}, State}.

handle_cast(_Msg, State0) ->
    State = maybe_shoot(State0),
    {noreply, State}.

handle_info(Info, State0) ->
    {noreply, State1} = do_handle_info(Info, State0),
    State = maybe_shoot(State1),
    {noreply, State}.

do_handle_info({gun_response, Client, _StreamRef, _IsFin, _StatusCode, _Headers},
               State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
do_handle_info({gun_response, Client, StreamRef, IsFin, StatusCode, Headers},
               State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    case take_sent_req(StreamRef, Requests) of
        error ->
            % Received 'gun_response' message from unknown stream
            % this may happen when the async cancel stream is sent too late
            {noreply, State};
        {expired, NRequests} ->
            ok = cancel_stream(Client, StreamRef),
            {noreply, State#state{requests = NRequests}};
        {?SENT_REQ(From, ExpireAt, undefined), NRequests} ->
            case IsFin of
                fin ->
                    gen_server:reply(From, {ok, StatusCode, Headers}),
                    {noreply, State#state{requests = NRequests}};
                nofin ->
                    Req = ?SENT_REQ(From, ExpireAt, {StatusCode, Headers, <<>>}),
                    {noreply, State#state{requests = put_sent_req(StreamRef, Req, NRequests)}}
            end
    end;

do_handle_info({gun_data, Client, _StreamRef, _IsFin, _Data},
               State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
do_handle_info({gun_data, Client, StreamRef, IsFin, Data},
               State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    case take_sent_req(StreamRef, Requests) of
        error ->
            % Received 'gun_data' message from unknown stream
            % this may happen when the async cancel stream is sent too late
            {noreply, State};
        {expired, NRequests} ->
            ok = cancel_stream(Client, StreamRef),
            {noreply, State#state{requests = NRequests}};
        {?SENT_REQ(From, ExpireAt, {StatusCode, Headers, Acc}), NRequests} ->
            case IsFin of
                fin ->
                    gen_server:reply(From, {ok, StatusCode, Headers, <<Acc/binary, Data/binary>>}),
                    {noreply, State#state{requests = NRequests}};
                nofin ->
                    Req = ?SENT_REQ(From, ExpireAt, {StatusCode, Headers, <<Acc/binary, Data/binary>>}),
                    {noreply, State#state{requests = put_sent_req(StreamRef, Req, NRequests)}}
            end
    end;

do_handle_info({gun_error, Client, _StreamRef, _Reason},
               State = #state{client = Client, enable_pipelining = false}) ->
    {noreply, State};
do_handle_info({gun_error, Client, StreamRef, Reason},
               State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    case take_sent_req(StreamRef, Requests) of
        error ->
            % Received 'gun_error' message from unknown stream
            % this may happen when the async cancel stream is sent too late
            % e.g. after the stream has been closed by gun, if we send a cancel stream
            % gun will reply with Reason={badstate,"The stream cannot be found."}
            {noreply, State};
        {expired, NRequests} ->
            {noreply, State#state{requests = NRequests}};
        {?SENT_REQ(From, _, _), NRequests} ->
            gen_server:reply(From, {error, Reason}),
            {noreply, State#state{requests = NRequests}}
    end;

do_handle_info({gun_up, Client, _}, State = #state{client = Client}) ->
    %% stale gun up after the caller gave up waiting in gun_await_up/5
    %% we can only hope it to be useful for the next call
    {noreply, State#state{gun_state = up}};

do_handle_info({gun_down, Client, _, _Reason, _KilledStreams, _},
               State = #state{client = Client, enable_pipelining = false, requests = Requests}) ->
    {noreply, State#state{gun_state = down, requests = clear_sent_reqs(Requests)}};
do_handle_info({gun_down, Client, _, Reason, KilledStreams, _},
               State = #state{client = Client, requests = Requests, enable_pipelining = true}) ->
    Reason =/= normal andalso Reason =/= closed andalso ?LOG(warning, "Received 'gun_down' message with reason: ~p", [Reason]),
    NRequests = lists:foldl(fun(StreamRef, Acc) ->
                                case take_sent_req(StreamRef, Acc) of
                                    error ->
                                        Acc;
                                    {expired, NAcc} ->
                                        NAcc;
                                    {?SENT_REQ(From, _, _), NAcc} ->
                                        gen_server:reply(From, {error, Reason}),
                                        NAcc
                                end
                            end, Requests, KilledStreams),
    {noreply, State#state{gun_state = down, requests = NRequests}};
do_handle_info({'DOWN', MRef, process, Client, Reason},
               State = #state{mref = MRef, client = Client, requests = Requests, enable_pipelining = EnablePipelining}) ->
    case EnablePipelining of
        true -> ok = reply_error_for_sent_reqs(Requests, Reason);
        false -> ok
    end,
    case open(State#state{requests = clear_sent_reqs(Requests)}) of
        {ok, NewState} ->
            {noreply, NewState};
        {error, _Reason} ->
            {noreply, State#state{mref = undefined, client = undefined}}
    end;
do_handle_info(continue, State) ->
    {noreply, State};
do_handle_info(Info, State) ->
    ?LOG(warning, "~p unnexpected_info: ~p", [?MODULE, Info]),
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
            MRef = erlang:monitor(process, ConnPid),
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
    %% this is just an async message sent to gun
    %% the gun stream process does really cancel
    %% anything, but just mark the receiving process (i.e. self())
    %% as inactive, however, there could be messages already
    %% delivered to self()'s mailbox
    %% or the stream process might send more messages
    %% before receiving the cancel message.
    _ = gun:cancel(Client, StreamRef),
    ok.

await_response(StreamRef, ExpireAt, Timeout0, State = #state{client = Client}) ->
    Timeout = max(Timeout0, 0),
    receive
        {gun_response, Client, StreamRef, fin, StatusCode, Headers} ->
           {reply, {ok, StatusCode, Headers}, State};
        {gun_response, Client, StreamRef, nofin, StatusCode, Headers} ->
            await_remaining_response(StreamRef, ExpireAt, State, {StatusCode, Headers, <<>>});
        {gun_error, Client, StreamRef, Reason} ->
            {reply, {error, Reason}, State};
        {gun_down, Client, _, Reason, _KilledStreams, _} ->
            {reply, {error, Reason}, State};
        {'DOWN', _MRef, process, Client, Reason} ->
            NState = case open(State) of
                        {ok, State1} -> State1;
                        {error, _Reason} -> State#state{mref = undefined, client = undefined}
                    end,
            {reply, {error, Reason}, NState};
        ?GEN_CALL_REQ(From, Call) ->
            State1 = enqueue_req(From, Call, State),
            %% keep waiting
            await_response(StreamRef, ExpireAt, timeout(ExpireAt), State1)
    after Timeout ->
        ok = cancel_stream(Client, StreamRef),
        {reply, {error, timeout}, State}
    end.

await_remaining_response(StreamRef, ExpireAt, State = #state{client = Client}, {StatusCode, Headers, Acc}) ->
    Timeout = timeout(ExpireAt),
    receive
        {gun_data, Client, StreamRef, fin, Data} ->
            {reply, {ok, StatusCode, Headers, <<Acc/binary, Data/binary>>}, State};
        {gun_data, Client, StreamRef, nofin, Data} ->
            await_remaining_response(StreamRef, ExpireAt, State, {StatusCode, Headers, <<Acc/binary, Data/binary>>});
        {gun_error, Client, StreamRef, Reason} ->
            {reply, {error, Reason}, State};
        {gun_down, Client, _, Reason, _KilledStreams, _} ->
            {reply, {error, Reason}, State};
        {'DOWN', _MRef, process, Client, Reason} ->
            NState = case open(State) of
                         {ok, State1} -> State1;
                         {error, _Reason} -> State#state{mref = undefined, client = undefined}
                     end,
            {reply, {error, Reason}, NState};
        ?GEN_CALL_REQ(From, Call) ->
            State1 = enqueue_req(From, Call, State),
            %% keep waiting
            await_remaining_response(StreamRef, ExpireAt, State1, {StatusCode, Headers, Acc})
    after Timeout ->
        ok = cancel_stream(Client, StreamRef),
        {reply, {error, timeout}, State}
    end.

timeout(ExpireAt) ->
    max(ExpireAt - now_(), 0).

now_() ->
    erlang:system_time(millisecond).

%% Improved version of erlang:demonitor(Ref, [flush]).
%% Only try to receive the 'DOWN' messages when it might have been sent.
-spec demon(reference()) -> ok.
demon(Ref) when is_reference(Ref) ->
    case erlang:demonitor(Ref, [info]) of
        true ->
            %% succeeded
            ok;
        _ ->
            %% '_', but not 'false' because this may change in the future according to OTP doc
            receive
                {'DOWN', Ref, process, _, _} ->
                    ok
            after 0 ->
                ok
            end
    end.

%% =================================================================================
%% sent requests
%% =================================================================================

%% upgrade from old format before 0.1.16
upgrade_requests(#{pending := _, sent := _} = Already) -> Already;
upgrade_requests(Map) when is_map(Map) ->
    #{pending => queue:new(), sent => Map}.

put_sent_req(StreamRef, Req, Requests0) ->
    Requests = #{sent := Sent} = upgrade_requests(Requests0),
    Requests#{sent := maps:put(StreamRef, Req, Sent)}.

take_sent_req(StreamRef, Requests0) ->
    Requests = #{sent := Sent} = upgrade_requests(Requests0),
    case maps:take(StreamRef, Sent) of
        error ->
            error;
        {Req, NewSent} ->
            case is_req_expired(Req, now_()) of
                true ->
                    {expired, Requests#{sent := NewSent}};
                false ->
                    {Req, Requests#{sent := NewSent}}
            end
    end.

is_req_expired(?SENT_REQ({Pid, _Ref}, ExpireAt, _), Now) ->
    Now > ExpireAt orelse (not erlang:is_process_alive(Pid)).

%% reply error to all callers which are waiting for the sent reqs
reply_error_for_sent_reqs(Requests0, Reason) ->
    #{sent := Sent} = upgrade_requests(Requests0),
    Now = now_(),
    lists:foreach(fun({_, ?SENT_REQ(From, _, _) = Req}) ->
                          case is_req_expired(Req, Now) of
                              true ->
                                  ok;
                              false ->
                                  gen_server:reply(From, {error, Reason})
                          end
                  end, maps:to_list(Sent)).

clear_sent_reqs(Requests0) ->
    Requests = upgrade_requests(Requests0),
    Requests#{sent := #{}}.

%% =================================================================================
%% handle calls from application layer
%% =================================================================================

%% enqueue the pending requests
enqueue_req(From, Req, #state{requests = Requests0} = State) ->
    #{pending := Pending} = Requests1 = upgrade_requests(Requests0),
    NewPending = case maps:get(prioritise_latest, Requests0, false) of
                     true -> queue:in_r(?PEND_REQ(From, Req), Pending);
                     false -> queue:in(?PEND_REQ(From, Req), Pending)
                 end,
    Requests = Requests1#{pending := NewPending},
    State#state{requests = Requests}.

%% call gun to shoot the request out
maybe_shoot(State) ->
    maybe_shoot(State, 0).

maybe_shoot(State, 100) ->
    %% we have shot 100 requests in a row
    %% give it a break, so mbye system messages get a chance to be handled
    self() ! continue,
    State;
maybe_shoot(#state{requests = #{pending := Pending0} = Requests0} = State0, Shots) ->
    case queue:out(Pending0) of
        {empty, _} ->
            State0;
        {{value, ?PEND_REQ(From, Req)}, Pending} ->
            Requests = Requests0#{pending := Pending},
            State1 = State0#state{requests = Requests},
            case handle_req(Req, From, State1) of
                {reply, Reply, State} ->
                    gen_server:reply(From, Reply),
                    %% continue shooting because there might be more
                    %% calls queued while evaluating handle_req/3
                    maybe_shoot(State, Shots + 1);
                {noreply, State} ->
                    maybe_shoot(State, Shots + 1)
            end
    end.

handle_req(Request = {_, _, _}, From,
           State = #state{client = undefined, gun_state = down}) ->
    %% no http client, start it
    case open(State) of
        {ok, NewState} ->
            handle_req(Request, From, NewState);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_req(Request = {_, _, ExpireAt}, From,
           State0 = #state{client = Client, mref = MRef, gun_state = down}) when is_pid(Client) ->
    Timeout = timeout(ExpireAt),
    %% wait for the http client to be ready
    {Res, State} = gun_await_up(Client, ExpireAt, Timeout, MRef, State0),
    case Res of
        {ok, _} ->
            handle_req(Request, From, State#state{gun_state = up});
        {error, connect_timeout} ->
            {reply, {error, connect_timeout}, State};
        {error, Reason} ->
            ok = demon(MRef),
            {reply, {error, Reason}, State#state{client = undefined, mref = undefined}}
    end;
handle_req({Method, Request, ExpireAt}, From,
           State = #state{client = Client,
                          requests = Requests,
                          enable_pipelining = EnablePipelining,
                          gun_state = up}) when is_pid(Client) ->
    %% timedout already by the time when handing the call
    case (Timeout = timeout(ExpireAt)) > 0 of
        true ->
            StreamRef = do_request(Client, Method, Request),
            case EnablePipelining of
                true ->
                    %% no need for the payload
                    Req = ?SENT_REQ(From, ExpireAt, ?undef),
                    {noreply, State#state{requests = put_sent_req(StreamRef, Req, Requests)}};
                false ->
                    await_response(StreamRef, ExpireAt, Timeout, State)
            end;
        false ->
            {noreply, State}
    end.

%% This is a copy of gun:wait_up/3
%% with the '$gen_call' clause added so the calls in the mail box
%% are collected into the queue in time
gun_await_up(Pid, ExpireAt, Timeout, MRef, State0) ->
    receive
        {gun_up, Pid, Protocol} ->
            {{ok, Protocol}, State0};
        {'DOWN', MRef, process, Pid, Reason} ->
            {{error, Reason}, State0};
        ?GEN_CALL_REQ(From, Call) ->
            State = enqueue_req(From, Call, State0),
            %% keep waiting
            NewTimeout = timeout(ExpireAt),
            gun_await_up(Pid, ExpireAt, NewTimeout, MRef, State)
    after Timeout ->
        {{error, connect_timeout}, State0}
    end.
