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
        , workers/1
        , get_client/1
        , simple_request/4
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

-define(RESPONSE(Status, Body, Headers), {response, Status, Body, Headers}).
-define(T_WAITUP, infinity).

-record(state, {
          pool      :: term(),
          id        :: pos_integer(),
          client    :: pid() | undefined,
          mref      :: reference() | undefined,
          host      :: inet:hostname() | inet:ip_address(),
          port      :: inet:port_number(),
          gun_opts  :: proplists:proplist(),
          gun_state :: down | up
         }).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

start_link(Pool, Id, Opts) ->
    gen_server:start_link(?MODULE, [Pool, Id, Opts], []).

simple_request(Worker, Method, Req, Timeout) ->
    case get_client(Worker) of
        {error, Reason} -> {error, Reason};
        {ok, ConnPid, MRef} ->
            StreamRef = do_request(ConnPid, Method, Req),
            await_response(ConnPid, StreamRef, Timeout, MRef)
    end.

await_response(ConnPid, StreamRef, Timeout, MRef) ->
    case gun:await(ConnPid, StreamRef, Timeout, MRef) of
        {error, Reason} ->
            ?LOG(error, "await reply failed: ~p", [Reason]),
            {error, Reason};
        {response, fin, Status, Headers} ->
            {ok, ?RESPONSE(Status, <<>>, Headers)};
        {response, nofin, Status, Headers} ->
            case gun:await_body(ConnPid, StreamRef, Timeout, MRef) of
                {ok, Body} ->
                    {ok, ?RESPONSE(Status, Body, Headers)};
                {error, Reason} ->
                    ?LOG(error, "await response body failed: ~p", [Reason]),
                    {error, Reason}
            end
    end.

get_client(Worker) ->
    gen_server:call(Worker, get_client).

request(Worker, Method, Req) ->
    request(Worker, Method, Req, 5000).

request(Worker, Method, Req, Timeout) ->
    gen_server:call(Worker, {Method, Req, Timeout}, Timeout + 1000).

workers(Pool) ->
    gproc_pool:active_workers(name(Pool)).

name(Pool) -> {?MODULE, Pool}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Opts]) ->
    State = #state{pool = Pool,
                   id = Id,
                   client = undefined,
                   mref = undefined,
                   host = proplists:get_value(host, Opts),
                   port = proplists:get_value(port, Opts),
                   gun_opts = gun_opts(Opts),
                   gun_state = down
                   },
    true = gproc_pool:connect_worker(ehttpc:name(Pool), {Pool, Id}),
    self() ! try_connect,
    {ok, State}.

handle_call(get_client, _From, State = #state{client = undefined}) ->
    self() ! try_connect,
    {reply, {error, conn_down}, State};

handle_call(get_client, _From, State = #state{client = Client, mref = MRef}) ->
    {reply, {ok, Client, MRef}, State};

handle_call(Req, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info(try_connect, State = #state{
                host = Host, port = Port,
                gun_opts = GunOpts, client = undefined}) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} when is_pid(ConnPid) ->
            MRef = monitor(process, ConnPid),
            ?LOG(warning, "connected to ~p successfully, gun: ~p",
                [{Host, Port}, ConnPid]),
            {noreply, State#state{mref = MRef, client = ConnPid}};
        {error, Reason} ->
            ?LOG(error, "try connect to ~p failed, reason: ~p",
                [{Host, Port}, Reason]),
            {noreply, State}
    end;
handle_info(try_connect, State) ->
    {noreply, State};

handle_info({gun_up, Client, _}, State = #state{client = Client}) ->
    ?LOG(warning, "gun connection ~p up", [Client]),
    {noreply, State#state{gun_state = up}};

handle_info({gun_down, Client, _, Reason, _, _}, State) ->
    ?LOG(warning, "gun connection ~p down: ~p", [Client, Reason]),
    {noreply, State#state{gun_state = down}};

handle_info({'DOWN', MRef, process, Client, Reason}, State = #state{mref = MRef, client = Client}) ->
    true = erlang:demonitor(MRef, [flush]),
    ?LOG(warning, "gun pid down: ~p, ~p", [Client, Reason]),
    erlang:send_after(2000, self(), try_connect),
    {noreply, State#state{mref = undefined, client = undefined}};

handle_info(Info, State) ->
    ?LOG(error, "Unexpected info: ~p, State: ~0p", [Info, State]),
    {noreply, State}.

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    gproc_pool:disconnect_worker(ehttpc:name(Pool), {Pool, Id}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

gun_opts(Opts) ->
    gun_opts(Opts, #{retry => 5,
                     retry_timeout => 1000,
                     connect_timeout => 5000,
                     protocols => [http],
                     http_opts => #{keepalive => infinity}}).

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
