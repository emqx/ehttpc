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
    request_async/5,
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
    format_status/1,
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

-type method() :: get | put | post | head | delete.
-type path() :: binary() | string().
-type headers() :: [{binary(), iodata()}].
-type body() :: iodata().
-type callback() :: {function(), list()}.
-type request() :: path() | {path(), headers()} | {path(), headers(), body()}.

-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(LOG(Level, Format, Args), logger:Level("ehttpc: " ++ Format, Args)).
-define(REQ(Method, Req, ExpireAt), {Method, Req, ExpireAt}).
-define(PEND_REQ(ReplyTo, Req), {ReplyTo, Req}).
-define(SENT_REQ(ReplyTo, ExpireAt, Acc), {ReplyTo, ExpireAt, Acc}).
-define(ASYNC_REQ(Method, Req, ExpireAt, ResultCallback),
    {async, Method, Req, ExpireAt, ResultCallback}
).
-define(GEN_CALL_REQ(From, Call), {'$gen_call', From, ?REQ(_, _, _) = Call}).
-define(undef, undefined).
-define(IS_POOL(Pool), (not is_tuple(Pool) andalso not is_pid(Pool))).

-record(state, {
    pool :: term(),
    id :: pos_integer(),
    client :: pid() | ?undef,
    %% no longer in use since 0.4.12 (changed to gun:start_link)
    mref :: reference() | ?undef,
    host :: inet:hostname() | inet:ip_address(),
    port :: inet:port_number(),
    enable_pipelining :: boolean() | non_neg_integer(),
    gun_opts :: gun:opts(),
    gun_state :: down | up,
    requests :: map(),
    proxy :: undefined | map()
}).

-type pool_name() :: any().
-type option() :: [{atom(), term()}].

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc For test, debug and troubleshooting.
get_state(PoolOrWorker) ->
    get_state(PoolOrWorker, minimal).

%% @doc For test, debug and troubleshooting.
get_state(Pool, Style) when ?IS_POOL(Pool) ->
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
        exit:Reason when
            Reason =:= normal;
            Reason =:= {shutdown, normal}
        ->
            %% Race condition: gun went down while checking health?
            %% Try again.
            health_check(Worker, Timeout);
        exit:Reason ->
            {error, {ehttpc_worker_down, Reason}}
    end.

request(Pool, Method, Request) ->
    request(Pool, Method, Request, 5000).

request(Pool, Method, Request, Timeout) ->
    request(Pool, Method, Request, Timeout, 2).

request(Pool, Method, Request, Timeout, Retry) when ?IS_POOL(Pool) ->
    request(ehttpc_pool:pick_worker(Pool), Method, Request, Timeout, Retry);
request({Pool, N}, Method, Request, Timeout, Retry) when ?IS_POOL(Pool) ->
    request(ehttpc_pool:pick_worker(Pool, N), Method, Request, Timeout, Retry);
request(Worker, Method, Request, Timeout, Retry) when is_pid(Worker) ->
    ExpireAt = fresh_expire_at(Timeout),
    CallTimeout =
        case Timeout of
            infinity -> infinity;
            T -> T + 500
        end,
    try gen_server:call(Worker, ?REQ(Method, Request, ExpireAt), CallTimeout) of
        %% gun will reply {gun_down, _Client, _, normal, _KilledStreams, _} message
        %% when connection closed by keepalive

        %% If `Reason' = `normal', we should just retry without
        %% consuming a retry credit, as it could be a race condition
        %% where the gun process is down (e.g.: when the server closes
        %% the connection), and then requests would be ignored while
        %% the `gun' process is terminating.
        {error, Reason} when
            Reason =:= normal;
            Reason =:= {shutdown, normal}
        ->
            ?tp(ehttpc_retry_gun_down_normal, #{}),
            request(Worker, Method, Request, Timeout, Retry);
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

%% @doc Send an async request. The callback is evaluated when an error happens or http response is received.
-spec request_async(pid(), method(), request(), timeout(), callback()) -> ok.
request_async(Worker, Method, Request, Timeout, ResultCallback) when is_pid(Worker) ->
    ExpireAt = fresh_expire_at(Timeout),
    _ = erlang:send(Worker, ?ASYNC_REQ(Method, Request, ExpireAt, ResultCallback)),
    ok.

workers(Pool) ->
    gproc_pool:active_workers(name(Pool)).

name(Pool) -> {?MODULE, Pool}.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Opts0]) ->
    process_flag(trap_exit, true),
    PrioLatest = proplists:get_bool(prioritise_latest, Opts0),
    #{opts := Opts, proxy := Proxy} = parse_proxy_opts(Opts0),
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
        },
        proxy = Proxy
    },
    true = gproc_pool:connect_worker(ehttpc:name(Pool), {Pool, Id}),
    {ok, State}.

handle_call({health_check, _}, _From, State = #state{gun_state = up}) ->
    {reply, ok, State};
handle_call({health_check, Timeout}, _From, State = #state{client = ?undef, gun_state = down}) ->
    case open(State) of
        {ok, NewState} ->
            do_after_gun_up(
                NewState,
                fresh_expire_at(Timeout),
                fun(State1) ->
                    {reply, ok, State1}
                end
            );
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call({health_check, Timeout}, _From, State = #state{client = Client, gun_state = down}) when
    is_pid(Client)
->
    ?tp(health_check_when_gun_client_not_ready, #{client => Client}),
    do_after_gun_up(
        State,
        fresh_expire_at(Timeout),
        fun(State1) ->
            {reply, ok, State1}
        end
    );
handle_call(?REQ(_Method, _Request, _ExpireAt) = Req, From, State0) ->
    State1 = enqueue_req(From, Req, upgrade_requests(State0)),
    State = maybe_shoot(State1),
    {noreply, State};
handle_call(Call, _From, State0) ->
    State = maybe_shoot(upgrade_requests(State0)),
    {reply, {error, {unexpected_call, Call}}, State}.

handle_cast(_Msg, State0) ->
    State = maybe_shoot(upgrade_requests(State0)),
    {noreply, State}.

handle_info(?ASYNC_REQ(Method, Request, ExpireAt, ResultCallback), State0) ->
    Req = ?REQ(Method, Request, ExpireAt),
    State1 = enqueue_req(ResultCallback, Req, upgrade_requests(State0)),
    State = maybe_shoot(State1),
    {noreply, State};
handle_info({suspend, Time}, State) ->
    %% only for testing
    timer:sleep(Time),
    {noreply, State};
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
        {?SENT_REQ(ReplyTo, _, _), NRequests} ->
            reply(ReplyTo, {error, Reason}),
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
    %% stale code for appup since 0.4.12
    handle_client_down(State, Reason);
do_handle_info({'EXIT', Client, Reason}, State = #state{client = Client}) ->
    handle_client_down(State, Reason);
do_handle_info(Info, State) ->
    ?LOG(warning, "~p unexpected_info: ~p, client: ~p", [?MODULE, Info, State#state.client]),
    State.

terminate(_Reason, #state{pool = Pool, id = Id, client = Client}) ->
    is_pid(Client) andalso gun:close(Client),
    gproc_pool:disconnect_worker(ehttpc:name(Pool), {Pool, Id}),
    ok.

format_status(Status = #{state := State}) ->
    Status#{state => format_state(State, minimal)}.

%% TODO
%% This is deprecated since OTP-25 in favor of `format_status/1`. Remove once
%% OTP-25 becomes minimum supported OTP version.
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
                    {?SENT_REQ(ReplyTo, _, _), NAcc} ->
                        reply(ReplyTo, {error, Reason}),
                        NAcc
                end
            end,
            Requests,
            KilledStreams
        ),
    State#state{requests = NRequests, gun_state = down}.

open(State = #state{host = Host, port = Port, gun_opts = GunOpts}) ->
    case gun:start_link(Host, Port, GunOpts) of
        {ok, ConnPid} when is_pid(ConnPid) ->
            {ok, State#state{client = ConnPid}};
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
gun_opts([{retry, _} | Opts], Acc) ->
    %% explicit ignore
    gun_opts(Opts, Acc);
gun_opts([{retry_timeout, _} | Opts], Acc) ->
    %% explicit ignore
    gun_opts(Opts, Acc);
gun_opts([{connect_timeout, ConnectTimeout} | Opts], Acc) ->
    gun_opts(Opts, Acc#{connect_timeout => ConnectTimeout});
gun_opts([{transport, Transport} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport => Transport});
gun_opts([{transport_opts, TransportOpts} | Opts], Acc) ->
    gun_opts(Opts, Acc#{transport_opts => TransportOpts});
gun_opts([_ | Opts], Acc) ->
    %% ignore by default
    gun_opts(Opts, Acc).

do_request(Client, head, {Path, Headers}) ->
    RequestRef = gun:head(Client, Path, Headers),
    finish_body_call_if_needed(Client, RequestRef, Headers, <<>>),
    RequestRef;
do_request(Client, head, Path) ->
    do_request(Client, head, {Path, []});
do_request(Client, get, {Path, Headers}) ->
    RequestRef = gun:get(Client, Path, Headers),
    finish_body_call_if_needed(Client, RequestRef, Headers, <<>>),
    RequestRef;
do_request(Client, patch, {Path, Headers, Body}) ->
    RequestRef = gun:patch(Client, Path, Headers, Body),
    finish_body_call_if_needed(Client, RequestRef, Headers, Body),
    RequestRef;
do_request(Client, post, {Path, Headers, Body}) ->
    RequestRef = gun:post(Client, Path, Headers, Body),
    finish_body_call_if_needed(Client, RequestRef, Headers, Body),
    RequestRef;
do_request(Client, put, {Path, Headers, Body}) ->
    RequestRef = gun:put(Client, Path, Headers, Body),
    finish_body_call_if_needed(Client, RequestRef, Headers, Body),
    RequestRef;
do_request(Client, delete, {Path, Headers}) ->
    RequestRef = gun:delete(Client, Path, Headers),
    finish_body_call_if_needed(Client, RequestRef, Headers, <<>>),
    RequestRef.

%% Finish the request only if the headers are set so that gun expect body data
%% to come with calls to gun:data/4. Otherwise, subsequent request will fail
%% with a function clause error.
finish_body_call_if_needed(Client, RequestRef, Headers, Body) ->
    case is_finish_body_call_needed(Headers, Body) of
        true ->
            gun:data(Client, RequestRef, fin, <<>>);
        false ->
            ok
    end.

%% The following function corresponds to request_io_from_headers from
%% src/gun_http.erl https://github.com/ninenines/gun commit id
%% 47ec03dcf0346ad827e5c8aa8c2bf9ac35398afe
%%
%% Gun checks the headers (in the same way as the following function) to detect
%% if more data is expected to be provided after the initial request with
%% gun:data/4.
is_finish_body_call_needed(Headers, <<>>) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, <<"0">>} ->
            false;
        {_, _Length} ->
            true;
        false ->
            is_content_type_field_set(Headers)
    end;
%% Gun always finish the request if the body parameter (iodata()) is something
%% else than an empty binary. This means that, for example, gun:post(Client,
%% Path, [{<<"content-type">>, <<datat>>}], <<>>) and gun:post(Client, Path,
%% [{<<"content-type">>, <<datat>>}], []) are not equivalent.
is_finish_body_call_needed(_Headers, _NotEmptyBin) ->
    false.

is_content_type_field_set(Headers) ->
    lists:keymember(<<"content-type">>, 1, Headers).

cancel_stream(fin, _Client, _StreamRef) ->
    %% nothing to cancel anyway
    %% otherwise gun will reply with a gun_error messsage
    %% which is then discarded anyway
    ok;
cancel_stream(nofin, Client, StreamRef) ->
    %% this is just an async message sent to gun
    %% the gun stream process does not really cancel
    %% anything, but just mark the receiving process (i.e. self())
    %% as inactive, however, there could be messages already
    %% delivered to self()'s mailbox
    %% or the stream process might send more messages
    %% before receiving the cancel message.
    _ = gun:cancel(Client, StreamRef),
    ok.

timeout(infinity = _ExpireAt) ->
    infinity;
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
            case is_sent_req_expired(Req, now_()) of
                true ->
                    {expired, Requests#{sent := NewSent}};
                false ->
                    {Req, Requests#{sent := NewSent}}
            end
    end.

is_sent_req_expired(?SENT_REQ(_From, infinity = _ExpireAt, _), _Now) ->
    false;
is_sent_req_expired(?SENT_REQ({Pid, _Ref}, ExpireAt, _), Now) when is_pid(Pid) ->
    %% for gen_server:call, it is aborted after timeout, there is no need to send
    %% reply to the caller
    Now > ExpireAt orelse (not erlang:is_process_alive(Pid));
is_sent_req_expired(?SENT_REQ(_, _, _), _) ->
    %% for async requests, there is no way to tell if the caller
    %% the provided result-callback should be evaluated or not,
    %% to be on the safe side, we never consider sent async-requests expired.
    %% that is, we may still try evaluate the result callback
    %% after the deadline.
    false.

%% reply error to all callers which are waiting for the sent reqs
reply_error_for_sent_reqs(#{sent := Sent} = R, Reason) ->
    Now = now_(),
    lists:foreach(
        fun({_, ?SENT_REQ(ReplyTo, _, _) = Req}) ->
            case is_sent_req_expired(Req, Now) of
                true ->
                    ok;
                false ->
                    reply(ReplyTo, {error, Reason})
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
    {PeekFun, OutFun} = peek_oldest_fn(Requests),
    {value, ?PEND_REQ(ReplyTo, ?REQ(_, _, ExpireAt))} = PeekFun(Pending),
    case is_integer(ExpireAt) andalso Now > ExpireAt of
        true ->
            {_, NewPendings} = OutFun(Pending),
            NewRequests = Requests#{pending => NewPendings, pending_count => PC - 1},
            ok = maybe_reply_timeout(ReplyTo),
            ?tp(?FUNCTION_NAME, #{}),
            drop_expired(NewRequests, Now);
        false ->
            Requests
    end.

%% For async-request, we evaluate the result-callback with {error, timeout}
maybe_reply_timeout({F, A}) when is_function(F) ->
    _ = erlang:apply(F, A ++ [{error, timeout}]),
    ok;
maybe_reply_timeout(_) ->
    %% This is not a callback, but the gen_server:call's From
    %% The caller should have alreay given up waiting for a reply,
    %% so no need to call gen_server:reply(From, {error, timeout})
    ok.

%% enqueue the pending requests
enqueue_req(ReplyTo, Req, #state{requests = Requests0} = State) ->
    #{
        pending := Pending,
        pending_count := PC
    } = Requests0,
    InFun = enqueue_latest_fn(Requests0),
    NewPending = InFun(?PEND_REQ(ReplyTo, Req), Pending),
    Requests = Requests0#{pending := NewPending, pending_count := PC + 1},
    State#state{requests = drop_expired(Requests)}.

%% call gun to shoot the request out
maybe_shoot(#state{enable_pipelining = EP, requests = Requests0, client = Client} = State0) ->
    #{sent := Sent} = Requests0,
    State = State0#state{requests = drop_expired(Requests0)},
    %% If the gun http client is down
    ClientDown = is_pid(Client) andalso (not is_process_alive(Client)),
    %% Or when too many has been sent already
    case ClientDown orelse should_cool_down(EP, maps:size(Sent)) of
        true ->
            %% Then we should cool down, and let the gun responses
            %% or 'EXIT' message to trigger the flow again
            ?tp(cool_down, #{enable_pipelining => EP}),
            State;
        false ->
            do_shoot(State)
    end.

do_shoot(#state{requests = #{pending_count := 0}} = State) ->
    State;
do_shoot(#state{requests = #{pending := Pending0, pending_count := N} = Requests0} = State0) ->
    {{value, ?PEND_REQ(ReplyTo, Req)}, Pending} = queue:out(Pending0),
    Requests = Requests0#{pending := Pending, pending_count := N - 1},
    State1 = State0#state{requests = Requests},
    case shoot(Req, ReplyTo, State1) of
        {reply, Reply, State} ->
            reply(ReplyTo, Reply),
            %% continue shooting because there might be more
            %% calls queued while evaluating handle_req/3
            maybe_shoot(State);
        {noreply, State} ->
            maybe_shoot(State)
    end.

shoot(
    Request = ?REQ(_, _, _),
    ReplyTo,
    State = #state{client = ?undef, gun_state = down}
) ->
    %% no http client, start it
    case open(State) of
        {ok, NewState} ->
            shoot(Request, ReplyTo, NewState);
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
shoot(
    Request = ?REQ(_, _Req, ExpireAt),
    ReplyTo,
    State0 = #state{client = Client, gun_state = down}
) when is_pid(Client) ->
    do_after_gun_up(
        State0,
        ExpireAt,
        fun(State) ->
            ?tp(gun_up, #{from => ReplyTo, req => _Req}),
            shoot(Request, ReplyTo, State)
        end
    );
shoot(
    ?REQ(Method, Request, ExpireAt),
    ReplyTo,
    State = #state{
        client = Client,
        requests = Requests,
        gun_state = up
    }
) when is_pid(Client) ->
    StreamRef = do_request(Client, Method, Request),
    ?tp(shot, #{from => ReplyTo, req => Request, reqs => Requests}),
    %% no need for the payload
    Req = ?SENT_REQ(ReplyTo, ExpireAt, ?undef),
    {noreply, State#state{requests = put_sent_req(StreamRef, Req, Requests)}}.

do_after_gun_up(State0 = #state{client = Client, mref = MRef}, ExpireAt, Fun) ->
    Timeout = timeout(ExpireAt),
    %% wait for the http client to be ready
    {Res, State} = gun_await_up(Client, ExpireAt, Timeout, MRef, State0),
    case Res of
        {ok, _} ->
            Fun(State);
        {error, connect_timeout} ->
            %% the caller can not wait logger
            %% but the connection is likely to be useful
            {reply, {error, connect_timeout}, State};
        {error, {proxy_error, _} = Error} ->
            %% We keep the client around because the proxy might still send data as part
            %% of the error response.
            {reply, {error, Error}, State};
        {error, Reason} ->
            case is_reference(MRef) of
                true ->
                    %% stale code for appup since 0.4.12
                    erlang:demonitor(MRef, [flush]);
                false ->
                    ok
            end,
            {reply, {error, Reason}, State#state{client = ?undef, mref = ?undef}}
    end.

%% This is a copy of gun:wait_up/3
%% with the '$gen_call' clause added so the calls in the mail box
%% are collected into the queue in time
gun_await_up(Pid, ExpireAt, Timeout, MRef, State0) ->
    receive
        {gun_up, Pid, Protocol} ->
            case State0#state.proxy of
                undefined ->
                    State = State0#state{gun_state = up},
                    {{ok, Protocol}, State};
                #{} = ProxyOpts ->
                    gun_connect_proxy(Pid, ExpireAt, Timeout, Protocol, ProxyOpts, State0)
            end;
        {'DOWN', MRef, process, Pid, {shutdown, Reason}} ->
            %% stale code for appup since 0.4.12
            {{error, Reason}, State0};
        {'DOWN', MRef, process, Pid, Reason} ->
            %% stale code for appup since 0.4.12
            {{error, Reason}, State0};
        {'EXIT', Pid, {shutdown, Reason}} ->
            {{error, Reason}, State0};
        {'EXIT', Pid, Reason} ->
            {{error, Reason}, State0};
        ?ASYNC_REQ(Method, Request, ExpireAt1, ResultCallback) ->
            Req = ?REQ(Method, Request, ExpireAt1),
            State = enqueue_req(ResultCallback, Req, State0),
            %% keep waiting
            NewTimeout = timeout(ExpireAt),
            gun_await_up(Pid, ExpireAt, NewTimeout, MRef, State);
        ?GEN_CALL_REQ(From, Call) ->
            State = enqueue_req(From, Call, State0),
            %% keep waiting
            NewTimeout = timeout(ExpireAt),
            gun_await_up(Pid, ExpireAt, NewTimeout, MRef, State)
    after Timeout ->
        {{error, connect_timeout}, State0}
    end.

gun_connect_proxy(Pid, ExpireAt, Timeout, Protocol, ProxyOpts, State0) ->
    StreamRef = gun:connect(Pid, ProxyOpts),
    gun_await_connect_proxy(Pid, StreamRef, ExpireAt, Timeout, Protocol, ProxyOpts, State0).

gun_await_connect_proxy(Pid, StreamRef, ExpireAt, Timeout, Protocol, ProxyOpts, State0) ->
    receive
        {gun_response, Pid, StreamRef, fin, 200, Headers} ->
            State = State0#state{gun_state = up},
            {{ok, {Protocol, Headers}}, State};
        {gun_response, Pid, StreamRef, _Fin, 407, _Headers} ->
            {{error, {proxy_error, unauthorized}}, State0};
        {gun_response, Pid, StreamRef, _Fin, StatusCode, Headers} ->
            {{error, {proxy_error, {StatusCode, Headers}}}, State0};
        ?ASYNC_REQ(Method, Request, ExpireAt1, ResultCallback) ->
            Req = ?REQ(Method, Request, ExpireAt1),
            State = enqueue_req(ResultCallback, Req, State0),
            %% keep waiting
            NewTimeout = timeout(ExpireAt),
            gun_await_connect_proxy(
                Pid, StreamRef, ExpireAt, NewTimeout, Protocol, ProxyOpts, State
            );
        ?GEN_CALL_REQ(From, Call) ->
            State = enqueue_req(From, Call, State0),
            %% keep waiting
            NewTimeout = timeout(ExpireAt),
            gun_await_connect_proxy(
                Pid, StreamRef, ExpireAt, NewTimeout, Protocol, ProxyOpts, State
            )
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
            ok = cancel_stream(IsFin, Client, StreamRef),
            State#state{requests = NRequests};
        {?SENT_REQ(ReplyTo, ExpireAt, ?undef), NRequests} ->
            %% gun_response, http head

            %% assert, no body yet
            ?undef = Data,
            case IsFin of
                fin ->
                    %% only http heads no body
                    reply(ReplyTo, {ok, StatusCode, Headers}),
                    State#state{requests = NRequests};
                nofin ->
                    %% start accumulating data
                    Req = ?SENT_REQ(ReplyTo, ExpireAt, {StatusCode, Headers, []}),
                    State#state{requests = put_sent_req(StreamRef, Req, NRequests)}
            end;
        {?SENT_REQ(ReplyTo, ExpireAt, {StatusCode0, Headers0, Data0}), NRequests} ->
            %% gun_data, http body

            %% assert
            ?undef = StatusCode,
            %% assert
            ?undef = Headers,
            case IsFin of
                fin ->
                    reply(
                        ReplyTo, {ok, StatusCode0, Headers0, iolist_to_binary([Data0, Data])}
                    ),
                    State#state{requests = NRequests};
                nofin ->
                    Req = ?SENT_REQ(ReplyTo, ExpireAt, {StatusCode0, Headers0, [Data0, Data]}),
                    State#state{requests = put_sent_req(StreamRef, Req, NRequests)}
            end
    end.

reply({F, A}, Result) when is_function(F) ->
    _ = erlang:apply(F, A ++ [Result]),
    ok;
reply(From, Result) ->
    gen_server:reply(From, Result).

peek_oldest_fn(#{prioritise_latest := true}) ->
    {fun queue:peek_r/1, fun queue:out_r/1};
peek_oldest_fn(_) ->
    {fun queue:peek/1, fun queue:out/1}.

enqueue_latest_fn(#{prioritise_latest := true}) ->
    fun queue:in_r/2;
enqueue_latest_fn(_) ->
    fun queue:in/2.

fresh_expire_at(infinity = _Timeout) ->
    infinity;
fresh_expire_at(Timeout) when is_integer(Timeout) ->
    now_() + Timeout.

parse_proxy_opts(Opts) ->
    %% Target host and port
    case proplists:get_value(proxy, Opts, undefined) of
        undefined ->
            #{opts => Opts, proxy => undefined};
        #{host := _, port := _} = ProxyOpts0 ->
            %% We open connection to proxy, then issue `gun:connect' to target host.
            {ProxyOpts, NewOpts} =
                lists:foldl(
                    fun(Key, {ProxyAcc, GunAcc}) ->
                        swap(Key, ProxyAcc, GunAcc)
                    end,
                    {ProxyOpts0, proplists:delete(proxy, Opts)},
                    [host, port, transport, {tls_opts, transport_opts}]
                ),
            #{opts => NewOpts, proxy => ProxyOpts}
    end.

swap(Key, Map, Proplist) when is_atom(Key) ->
    swap({Key, Key}, Map, Proplist);
swap({KeyM, KeyP}, Map0, Proplist0) when is_map_key(KeyM, Map0) ->
    ValueFromMap = maps:get(KeyM, Map0),
    Map = maps:remove(KeyM, Map0),
    case take_proplist(KeyP, Proplist0) of
        {ValueFromProplist, Proplist} ->
            {Map#{KeyM => ValueFromProplist}, [{KeyP, ValueFromMap} | Proplist]};
        error ->
            {Map, [{KeyP, ValueFromMap} | Proplist0]}
    end;
swap({KeyM, KeyP}, Map0, Proplist0) ->
    case take_proplist(KeyP, Proplist0) of
        {ValueFromProplist, Proplist} ->
            {Map0#{KeyM => ValueFromProplist}, Proplist};
        error ->
            {Map0, Proplist0}
    end.

take_proplist(Key, Proplist0) ->
    Proplist1 = lists:keydelete(Key, 1, Proplist0),
    case lists:keyfind(Key, 1, Proplist0) of
        false ->
            error;
        {Key, ValueFromProplist} ->
            {ValueFromProplist, Proplist1}
    end.

-ifdef(TEST).

prioritise_latest_test() ->
    Opts = #{prioritise_latest => true},
    Seq = [1, 2, 3, 4],
    In = enqueue_latest_fn(Opts),
    {PeekOldest, OutOldest} = peek_oldest_fn(Opts),
    Q = lists:foldl(fun(I, QIn) -> In(I, QIn) end, queue:new(), Seq),
    ?assertEqual({value, 1}, PeekOldest(Q)),
    ?assertMatch({{value, 1}, _}, OutOldest(Q)),
    ?assertMatch({{value, 4}, _}, queue:out(Q)).

prioritise_oldest_test() ->
    Opts = #{prioritise_latest => false},
    Seq = [1, 2, 3, 4],
    In = enqueue_latest_fn(Opts),
    {PeekOldest, OutOldest} = peek_oldest_fn(Opts),
    Q = lists:foldl(fun(I, QIn) -> In(I, QIn) end, queue:new(), Seq),
    ?assertEqual({value, 1}, PeekOldest(Q)),
    ?assertMatch({{value, 1}, _}, OutOldest(Q)),
    ?assertMatch({{value, 1}, _}, queue:out(Q)).

-endif.
