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
-export([
    start_link/3,
    request/3,
    request/4,
    request/5,
    workers/1,
    health_check/2,
    name/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    format_status/2,
    format_state/2
]).

%% for test
-export([
    get_state/1,
    get_state/2,
    upgrade_requests/1,
    downgrade_requests/1
]).

-export_type([
    pool_name/0,
    option/0
]).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(LOG(Level, Format, Args), logger:Level("ehttpc: " ++ Format, Args)).
-define(REQ_CALL(Method, Req, ExpireAt), {Method, Req, ExpireAt}).
-define(PEND_REQ(From, Req), {From, Req}).
-define(SENT_REQ(StreamRef, ExpireAt, Acc), {StreamRef, ExpireAt, Acc}).
-define(GEN_CALL_REQ(From, Call), {'$gen_call', From, ?REQ_CALL(_, _, _) = Call}).
-define(undef, undefined).

-record(state, {
    pool :: term(),
    id :: pos_integer(),
    client :: pid() | ?undef,
    mref :: reference() | ?undef,
    host :: inet:hostname() | inet:ip_address(),
    port :: inet:port_number(),
    enable_pipelining :: boolean() | non_neg_integer(),
    gun_opts :: gun:opts(),
    gun_state :: down | up,
    requests :: map()
}).

-type pool_name() :: atom().
-type option() :: [{atom(), term()}].

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc For test, debug and troubleshooting.
get_state(PoolOrWorker) ->
    get_state(PoolOrWorker, minimal).

%% @doc For test, debug and troubleshooting.
get_state(Pool, Style) when is_atom(Pool) ->
    Worker = ehttpc_pool:pick_worker(Pool),
    {Worker, get_state(Worker, Style)};
get_state(Worker, Style) when is_pid(Worker) ->
    State = sys:get_state(Worker),
    format_state(State, Style).

start_link(Pool, Id, Opts) ->
    gen_server:start_link(?MODULE, [Pool, Id, Opts], []).

-spec health_check(pid(), integer()) -> ok | {error, term()}.
health_check(Worker, Timeout) ->
    CallTimeout = Timeout + timer:seconds(2),
    try
        gen_server:call(Worker, {health_check, Timeout}, CallTimeout)
    catch
        exit:{timeout, _Details} ->
            {error, timeout};
        exit:Reason ->
            {error, {ehttpc_worker_down, Reason}}
    end.

request(Pool, Method, Request) ->
    request(Pool, Method, Request, 5000).

request(Pool, Method, Request, Timeout) ->
    request(Pool, Method, Request, Timeout, 2).

request(Pool, Method, Request, Timeout, Retry) when is_atom(Pool) ->
    request(ehttpc_pool:pick_worker(Pool), Method, Request, Timeout, Retry);
request({Pool, N}, Method, Request, Timeout, Retry) when is_atom(Pool) ->
    request(ehttpc_pool:pick_worker(Pool, N), Method, Request, Timeout, Retry);
request(Worker, Method, Request, Timeout, Retry) when is_pid(Worker) ->
    ExpireAt = now_() + Timeout,
    try gen_server:call(Worker, ?REQ_CALL(Method, Request, ExpireAt), Timeout + 500) of
        %% gun will reply {gun_down, _Client, _, normal, _KilledStreams, _} message
        %% when connection closed by keepalive
        {error, Reason} when Retry < 1 ->
            {error, Reason};
        {error, _} ->
            request(Worker, Method, Request, Timeout, Retry - 1);
        Other ->
            Other
    catch
        exit:{timeout, _Details} ->
            {error, timeout};
        exit:Reason ->
            {error, {ehttpc_worker_down, Reason}}
    end.

workers(Pool) ->
    gproc_pool:active_workers(name(Pool)).

name(Pool) -> {?MODULE, Pool}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Opts]) ->
    process_flag(trap_exit, true),
    PrioLatest = proplists:get_bool(prioritise_latest, Opts),
    State = #state{
        pool = Pool,
        id = Id,
        client = ?undef,
        mref = ?undef,
        host = proplists:get_value(host, Opts),
        port = proplists:get_value(port, Opts),
        enable_pipelining = proplists:get_value(enable_pipelining, Opts, false),
        gun_opts = gun_opts(Opts),
        gun_state = down,
        requests = #{
            pending => queue:new(),
            pending_count => 0,
            sent => #{},
            prioritise_latest => PrioLatest
        }
    },
    true = gproc_pool:connect_worker(ehttpc:name(Pool), {Pool, Id}),
    {ok, State}.

handle_call({health_check, _}, _From, State = #state{gun_state = up}) ->
    {reply, ok, State};
handle_call({health_check, Timeout}, _From, State = #state{gun_state = down}) ->
    case open(State) of
        {ok, NewState} ->
            do_after_gun_up(
                NewState,
                now_() + Timeout,
                fun(State1) ->
                    {reply, ok, State1}
                end
            );
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(?REQ_CALL(_Method, _Request, _ExpireAt) = Req, From, State0) ->
    State1 = enqueue_req(From, Req, upgrade_requests(State0)),
    State = maybe_shoot(State1),
    {noreply, State};
handle_call(Call, _From, State0) ->
    State = maybe_shoot(upgrade_requests(State0)),
    {reply, {error, {unexpected_call, Call}}, State}.

handle_cast(_Msg, State0) ->
    State = maybe_shoot(upgrade_requests(State0)),
    {noreply, State}.

handle_info(Info, State0) ->
    State1 = do_handle_info(Info, upgrade_requests(State0)),
    State = maybe_shoot(State1),
    {noreply, State}.

do_handle_info(
    {gun_response, Client, StreamRef, IsFin, StatusCode, Headers},
    #state{client = Client} = State
) ->
    handle_gun_reply(State, Client, StreamRef, IsFin, StatusCode, Headers, ?undef);
do_handle_info(
    {gun_data, Client, StreamRef, IsFin, Data},
    #state{client = Client} = State
) ->
    handle_gun_reply(State, Client, StreamRef, IsFin, ?undef, ?undef, Data);
do_handle_info(
    {gun_error, Client, StreamRef, Reason},
    State = #state{client = Client, requests = Requests}
) ->
    case take_sent_req(StreamRef, Requests) of
        error ->
            % Received 'gun_error' message from unknown stream
            % this may happen when the async cancel stream is sent too late
            % e.g. after the stream has been closed by gun, if we send a cancel stream
            % gun will reply with Reason={badstate,"The stream cannot be found."}
            State;
        {expired, NRequests} ->
            State#state{requests = NRequests};
        {?SENT_REQ(From, _, _), NRequests} ->
            gen_server:reply(From, {error, Reason}),
            State#state{requests = NRequests}
    end;
do_handle_info({gun_up, Client, _}, State = #state{client = Client}) ->
    %% stale gun up after the caller gave up waiting in gun_await_up/5
    %% we can only hope it to be useful for the next call
    State#state{gun_state = up};
do_handle_info(
    {gun_down, Client, _, Reason, KilledStreams, _},
    State = #state{client = Client}
) ->
    Reason =/= normal andalso Reason =/= closed andalso
        ?LOG(warning, "Received 'gun_down' message with reason: ~p", [Reason]),
    NewState = handle_gun_down(State, KilledStreams, Reason),
    NewState;
do_handle_info(
    {'DOWN', MRef, process, Client, Reason},
    State = #state{mref = MRef, client = Client}
) ->
    handle_client_down(State, Reason);
do_handle_info(Info, State) ->
    ?LOG(warning, "~p unexpected_info: ~p, client: ~p", [?MODULE, Info, State#state.client]),
    State.

terminate(_Reason, #state{pool = Pool, id = Id, client = Client}) ->
    is_pid(Client) andalso gun:close(Client),
    gproc_pool:disconnect_worker(ehttpc:name(Pool), {Pool, Id}),
    ok.

%% NOTE: the git tag 0.1.0 was re-tagged
%% the actual version in use in EMQX 4.2 had requests missing
code_change({down, _Vsn}, State, [no_requests]) ->
    %% downgrage to a version before 'requests' and 'enable_pipelining' were added
    #state{
        pool = Pool,
        id = ID,
        client = Client,
        mref = MRef,
        host = Host,
        port = Port,
        gun_opts = GunOpts,
        gun_state = GunState
    } = State,
    {ok, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState}};
code_change({down, _Vsn}, State, [no_enable_pipelining]) ->
    %% downgrade to a version before 'enable_pipelining' was added
    #state{
        pool = Pool,
        id = ID,
        client = Client,
        mref = MRef,
        host = Host,
        port = Port,
        gun_opts = GunOpts,
        gun_state = GunState,
        requests = Requests
    } = State,
    OldRequests = downgrade_requests(Requests),
    {ok, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState, OldRequests}};
code_change({down, _Vsn}, #state{requests = Requests} = State, [downgrade_requests]) ->
    %% downgrade to a version which had old format 'requests'
    OldRequests = downgrade_requests(Requests),
    {ok, State#state{requests = OldRequests}};
%% below are upgrade instructions
code_change(_Vsn, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState}, _Extra) ->
    %% upgrade from a version before 'requests' field was added
    {ok, #state{
        pool = Pool,
        id = ID,
        client = Client,
        mref = MRef,
        host = Host,
        port = Port,
        enable_pipelining = true,
        gun_opts = GunOpts,
        gun_state = GunState,
        requests = upgrade_requests(#{})
    }};
code_change(_Vsn, {state, Pool, ID, Client, MRef, Host, Port, GunOpts, GunState, Requests}, _) ->
    %% upgrade from a version before 'enable_pipelining' filed was added
    {ok, #state{
        pool = Pool,
        id = ID,
        client = Client,
        mref = MRef,
        host = Host,
        port = Port,
        enable_pipelining = true,
        gun_opts = GunOpts,
        gun_state = GunState,
        requests = upgrade_requests(Requests)
    }};
code_change(_Vsn, State, _) ->
    %% upgrade from a version ahving old format 'requests' field
    {ok, upgrade_requests(State)}.

format_status(_Opt, [_PDict, State]) ->
    format_state(State, minimal).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

format_state(State, Style) ->
    Fields = record_info(fields, state),
    Map = maps:from_list(lists:zip(Fields, tl(tuple_to_list(State)))),
    case Style of
        normal -> Map;
        minimal -> Map#{requests => summary_requests(maps:get(requests, Map))}
    end.

summary_requests(#{sent := Sent} = Reqs) ->
    Reqs#{
        pending => {"..."},
        sent => maps:size(Sent)
    }.

handle_client_down(#state{requests = Requests0} = State, Reason) ->
    ?tp(?FUNCTION_NAME, Requests0),
    Requests = reply_error_for_sent_reqs(Requests0, Reason),
    State#state{
        requests = Requests,
        mref = ?undef,
        client = ?undef,
        gun_state = down
    }.

handle_gun_down(#state{requests = Requests} = State, KilledStreams, Reason) ->
    ?tp(?FUNCTION_NAME, #{requests => Requests, reason => Reason}),
    NRequests =
        lists:foldl(
            fun(StreamRef, Acc) ->
                case take_sent_req(StreamRef, Acc) of
                    error ->
                        Acc;
                    {expired, NAcc} ->
                        NAcc;
                    {?SENT_REQ(From, _, _), NAcc} ->
                        gen_server:reply(From, {error, Reason}),
                        NAcc
                end
            end,
            Requests,
            KilledStreams
        ),
    State#state{requests = NRequests, gun_state = down}.

open(State = #state{host = Host, port = Port, gun_opts = GunOpts}) ->
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} when is_pid(ConnPid) ->
            MRef = erlang:monitor(process, ConnPid),
            {ok, State#state{mref = MRef, client = ConnPid}};
        {error, Reason} ->
            {error, Reason}
    end.

gun_opts(Opts) ->
    %% We do not allow gun to retry,
    %% because we have retry around the gen_server call
    %% retry at lower level will likely cause
    %% gen_server callers to time out anyway
    GunNoRetry = 0,
    gun_opts(Opts, #{
        retry => GunNoRetry,
        connect_timeout => 5000,
        %% The keepalive mechanism of gun will send "\r\n" for keepalive,
        %% which may cause misjudgment by some servers, so we disabled it by default
        http_opts => #{keepalive => infinity},
        protocols => [http]
    }).

gun_opts([], Acc) ->
    Acc;
gun_opts([{retry, _} | _Opts], _Acc) ->
    error({not_allowd_opts, retry});
gun_opts([{retry_timeout, _} | _Opts], _Acc) ->
    error({not_allowd_opts, retry_timeout});
gun_opts([{connect_timeout, ConnectTimeout} | Opts], Acc) ->
    gun_opts(Opts, Acc#{connect_timeout => ConnectTimeout});
gun_opts([{transport, Transport} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport => Transport});
gun_opts([{transport_opts, TransportOpts} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport_opts => TransportOpts});
gun_opts([_ | Opts], Acc) ->
    gun_opts(Opts, Acc).

do_request(Client, head, {Path, Headers}) ->
    gun:head(Client, Path, Headers);
do_request(Client, head, Path) ->
    do_request(Client, head, {Path, []});
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
    %% the gun stream process does not really cancel
    %% anything, but just mark the receiving process (i.e. self())
    %% as inactive, however, there could be messages already
    %% delivered to self()'s mailbox
    %% or the stream process might send more messages
    %% before receiving the cancel message.
    _ = gun:cancel(Client, StreamRef),
    ok.

timeout(ExpireAt) ->
    max(ExpireAt - now_(), 0).

now_() ->
    erlang:system_time(millisecond).

%% =================================================================================
%% sent requests
%% =================================================================================

%% downgrade will cause all the pending calls to timeout
downgrade_requests(#{pending := _PendingCalls, sent := Sent}) -> Sent;
downgrade_requests(Already) -> Already.

%% upgrade from old format before 0.1.16
upgrade_requests(#state{requests = Requests} = State) ->
    State#state{requests = upgrade_requests(Requests)};
upgrade_requests(#{pending := _, sent := _} = Already) ->
    Already;
upgrade_requests(Map) when is_map(Map) ->
    #{
        pending => queue:new(),
        pending_count => 0,
        sent => Map,
        prioritise_latest => false
    }.

put_sent_req(StreamRef, Req, #{sent := Sent} = Requests) ->
    Requests#{sent := maps:put(StreamRef, Req, Sent)}.

take_sent_req(StreamRef, #{sent := Sent} = Requests) ->
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
reply_error_for_sent_reqs(#{sent := Sent} = R, Reason) ->
    Now = now_(),
    lists:foreach(
        fun({_, ?SENT_REQ(From, _, _) = Req}) ->
            case is_req_expired(Req, Now) of
                true ->
                    ok;
                false ->
                    gen_server:reply(From, {error, Reason})
            end
        end,
        maps:to_list(Sent)
    ),
    R#{sent := #{}}.

%% allow 100 async requests maximum when enable_pipelining is 'true'
%% allow only 1 async request when enable_pipelining is 'false'
%% otherwise stop shooting at the number limited by enable_pipelining
should_cool_down(true, Sent) -> Sent >= 100;
should_cool_down(false, Sent) -> Sent > 0;
should_cool_down(N, Sent) when is_integer(N) -> Sent >= N.

%% Continue droping expired requests, to avoid the state RAM usage
%% explosion if http client can not keep up.
drop_expired(#{pending_count := 0} = Requests) ->
    Requests;
drop_expired(Requests) ->
    drop_expired(Requests, now_()).

drop_expired(#{pending_count := 0} = Requests, _Now) ->
    Requests;
drop_expired(#{pending := Pending, pending_count := PC} = Requests, Now) ->
    {PeekFun, OutFun} =
        case maps:get(prioritise_latest, Requests, false) of
            true ->
                {fun queue:peek_r/1, fun queue:out_r/1};
            false ->
                {fun queue:peek/1, fun queue:out/1}
        end,
    {value, ?PEND_REQ(_, ?REQ_CALL(_, _, ExpireAt))} = PeekFun(Pending),
    case Now > ExpireAt of
        true ->
            {_, NewPendings} = OutFun(Pending),
            NewRequests = Requests#{pending => NewPendings, pending_count => PC - 1},
            drop_expired(NewRequests, Now);
        false ->
            Requests
    end.

%% enqueue the pending requests
enqueue_req(From, Req, #state{requests = Requests0} = State) ->
    #{
        pending := Pending,
        pending_count := PC
    } = Requests0,
    NewPending =
        case maps:get(prioritise_latest, Requests0, false) of
            true -> queue:in_r(?PEND_REQ(From, Req), Pending);
            false -> queue:in(?PEND_REQ(From, Req), Pending)
        end,
    Requests = Requests0#{pending := NewPending, pending_count := PC + 1},
    State#state{requests = drop_expired(Requests)}.

%% call gun to shoot the request out
maybe_shoot(#state{enable_pipelining = EP, requests = Requests0, client = Client} = State0) ->
    #{sent := Sent} = Requests0,
    State = State0#state{requests = drop_expired(Requests0)},
    %% If the gun http client is down
    ClientDown = is_pid(Client) andalso (not is_process_alive(Client)),
    %% Or when it too many has been sent already
    case ClientDown orelse should_cool_down(EP, maps:size(Sent)) of
        true ->
            %% Then we should cool down, and let the gun responses
            %% or 'DOWN' message to trigger the flow again
            ?tp(cool_down, #{enable_pipelining => EP}),
            State;
        false ->
            do_shoot(State)
    end.

do_shoot(#state{requests = #{pending_count := 0}} = State) ->
    State;
do_shoot(#state{requests = #{pending := Pending0, pending_count := N} = Requests0} = State0) ->
    {{value, ?PEND_REQ(From, Req)}, Pending} = queue:out(Pending0),
    Requests = Requests0#{pending := Pending, pending_count := N - 1},
    State1 = State0#state{requests = Requests},
    case shoot(Req, From, State1) of
        {reply, Reply, State} ->
            gen_server:reply(From, Reply),
            %% continue shooting because there might be more
            %% calls queued while evaluating handle_req/3
            maybe_shoot(State);
        {noreply, State} ->
            maybe_shoot(State)
    end.

shoot(
    Request = ?REQ_CALL(_, _, _),
    From,
    State = #state{client = ?undef, gun_state = down}
) ->
    %% no http client, start it
    case open(State) of
        {ok, NewState} ->
            shoot(Request, From, NewState);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
shoot(
    Request = ?REQ_CALL(_, _Req, ExpireAt),
    From,
    State0 = #state{client = Client, gun_state = down}
) when is_pid(Client) ->
    do_after_gun_up(
        State0,
        ExpireAt,
        fun(State) ->
            ?tp(gun_up, #{from => From, req => _Req}),
            shoot(Request, From, State)
        end
    );
shoot(
    ?REQ_CALL(Method, Request, ExpireAt),
    From,
    State = #state{
        client = Client,
        requests = Requests,
        gun_state = up
    }
) when is_pid(Client) ->
    StreamRef = do_request(Client, Method, Request),
    ?tp(shot, #{from => From, req => Request, reqs => Requests}),
    %% no need for the payload
    Req = ?SENT_REQ(From, ExpireAt, ?undef),
    {noreply, State#state{requests = put_sent_req(StreamRef, Req, Requests)}}.

do_after_gun_up(State0 = #state{client = Client, mref = MRef}, ExpireAt, Fun) ->
    Timeout = timeout(ExpireAt),
    %% wait for the http client to be ready
    {Res, State} = gun_await_up(Client, ExpireAt, Timeout, MRef, State0),
    case Res of
        {ok, _} ->
            Fun(State#state{gun_state = up});
        {error, connect_timeout} ->
            %% the caller can not wait logger
            %% but the connection is likely to be useful
            {reply, {error, connect_timeout}, State};
        {error, Reason} ->
            erlang:demonitor(MRef, [flush]),
            {reply, {error, Reason}, State#state{client = ?undef, mref = ?undef}}
    end.

%% This is a copy of gun:wait_up/3
%% with the '$gen_call' clause added so the calls in the mail box
%% are collected into the queue in time
gun_await_up(Pid, ExpireAt, Timeout, MRef, State0) ->
    receive
        {gun_up, Pid, Protocol} ->
            {{ok, Protocol}, State0};
        {'DOWN', MRef, process, Pid, {shutdown, Reason}} ->
            {{error, Reason}, State0};
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

%% normal handling of gun_response and gun_data reply
handle_gun_reply(State, Client, StreamRef, IsFin, StatusCode, Headers, Data) ->
    #state{requests = Requests} = State,
    case take_sent_req(StreamRef, Requests) of
        error ->
            %% Received 'gun_data' message from unknown stream
            %% this may happen when the async cancel stream is sent too late
            State;
        {expired, NRequests} ->
            %% the call is expired, caller is no longer waiting for a reply
            ok = cancel_stream(Client, StreamRef),
            State#state{requests = NRequests};
        {?SENT_REQ(From, ExpireAt, ?undef), NRequests} ->
            %% gun_response, http head

            %% assert, no body yet
            ?undef = Data,
            case IsFin of
                fin ->
                    %% only http heads no body
                    gen_server:reply(From, {ok, StatusCode, Headers}),
                    State#state{requests = NRequests};
                nofin ->
                    %% start accumulating data
                    Req = ?SENT_REQ(From, ExpireAt, {StatusCode, Headers, []}),
                    State#state{requests = put_sent_req(StreamRef, Req, NRequests)}
            end;
        {?SENT_REQ(From, ExpireAt, {StatusCode0, Headers0, Data0}), NRequests} ->
            %% gun_data, http body

            %% assert
            ?undef = StatusCode,
            %% assert
            ?undef = Headers,
            case IsFin of
                fin ->
                    gen_server:reply(
                        From, {ok, StatusCode0, Headers0, iolist_to_binary([Data0, Data])}
                    ),
                    State#state{requests = NRequests};
                nofin ->
                    Req = ?SENT_REQ(From, ExpireAt, {StatusCode0, Headers0, [Data0, Data]}),
                    State#state{requests = put_sent_req(StreamRef, Req, NRequests)}
            end
    end.
