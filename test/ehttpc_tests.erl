%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(ehttpc_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(POOL, <<"testpool">>).
-define(PORT, (60000 + ?LINE)).

-define(WITH_SERVER(Opts, Expr),
    with_server(Opts, fun() -> Expr end)
).
-define(WITH_POOL(PoolOpts, Expr),
    with_pool(PoolOpts, fun() -> Expr end)
).

-define(WITH(ServerOpts, PoolOpts, Expr),
    ?WITH_SERVER(ServerOpts, ?WITH_POOL(PoolOpts, Expr))
).

send_10_test_() ->
    Port1 = ?PORT,
    Port2 = ?PORT,
    ServerOpts1 = #{port => Port1, name => ?FUNCTION_NAME, delay => {rand, 300}, oneoff => true},
    ServerOpts2 = #{port => Port2, name => ?FUNCTION_NAME, delay => {rand, 300}, oneoff => false},
    PoolOpts1 = pool_opts(Port1, false),
    PoolOpts2 = pool_opts(Port2, false),
    [
        %% allow one retry for oneoff=true server, because of the 'DOWN' message race
        {"oneoff=true", fun() -> ?WITH(ServerOpts1, PoolOpts1, req_sync(10, 1000, 1)) end},
        {"oneoff=false", fun() -> ?WITH(ServerOpts2, PoolOpts2, req_sync(10)) end}
    ].

kill_gun_resume_test() ->
    Port = ?PORT,
    ServerOpts = #{port => Port, name => ?FUNCTION_NAME, delay => timer:seconds(30)},
    PoolOpts = pool_opts(Port, false),
    ?WITH(
        ServerOpts,
        PoolOpts,
        begin
            %% send a request and wait for it to timeout
            Req1 = req(1),
            Req2 = req(2),
            {error, timeout} = ehttpc:request(?POOL, delete, Req1, 10, 0),
            {ok, _} = ?block_until(#{?snk_kind := gun_up, req := Req1}, 1000, infinity),
            {ok, _} = ?block_until(#{?snk_kind := shot, req := Req1}, 1000, infinity),
            {_, #{client := Client}} = ehttpc:get_state(?POOL),
            %% this call will be blocked
            Tester = self(),
            {Pid, MRef} = spawn_monitor(
                fun() ->
                    Tester ! ready,
                    exit({return, ehttpc:request(?POOL, delete, Req2, 2_000, 0)})
                end
            ),
            receive
                ready -> ok
            end,
            timer:sleep(10),
            {_, #{requests := Reqs}} = ehttpc:get_state(?POOL),
            %% expect one sent, one pending
            #{pending_count := 1, sent := Sent} = Reqs,
            ?assertEqual(1, Sent),
            %% kill the client
            exit(Client, kill),
            {ok, _} = ?block_until(#{?snk_kind := handle_client_down}, 1000, infinity),
            {ok, _} = ?block_until(#{?snk_kind := gun_up, req := Req2}, 1000, infinity),
            {ok, _} = ?block_until(#{?snk_kind := shot, req := Req2}, 1000, infinity),
            {_, #{client := Client2}} = ehttpc:get_state(?POOL),
            ?assert(erlang:is_process_alive(Client2)),
            exit(Client2, kill),
            receive
                {'DOWN', MRef, process, Pid, Result} ->
                    ?assertEqual({return, {error, killed}}, Result)
            end
        end
    ).

send_100_test_() ->
    Port = ?PORT,
    ServerOpts1 = #{port => Port, name => ?FUNCTION_NAME, delay => 3, oneoff => true},
    ServerOpts2 = #{port => Port, name => ?FUNCTION_NAME, delay => {rand, 3}, oneoff => false},
    PoolOpts1 = pool_opts(Port, false),
    PoolOpts2 = pool_opts(Port, true),
    [
        %% allow one retry for oneoff=true server, because of the 'DOWN' message race
        {"oneoff=true", fun() -> ?WITH(ServerOpts1, PoolOpts1, req_sync(100, 1000, 1)) end},
        {"oneoff=false", fun() -> ?WITH(ServerOpts2, PoolOpts2, req_async(100)) end}
    ].

send_1000_async_pipeline_test_() ->
    TestTimeout = 30,
    Port = ?PORT,
    Opts1 = pool_opts(Port, true),
    Opts3 = pool_opts("localhost", Port, true, true),
    F = fun(Opts) ->
        fun() ->
            with_server(
                Port,
                ?FUNCTION_NAME,
                0,
                fun() ->
                    with_pool(
                        Opts,
                        fun() -> req_async(1000, timer:seconds(TestTimeout)) end
                    )
                end
            )
        end
    end,
    [
        {timeout, TestTimeout + 1, F(Opts1)},
        {timeout, TestTimeout + 1, F(Opts3)}
    ].

send_1000_async_no_pipeline_test_() ->
    TestTimeout = 30,
    Port = ?PORT,
    Opts2 = pool_opts(Port, false),
    Opts4 = pool_opts("localhost", Port, false, true),
    F = fun(Opts) ->
        fun() ->
            with_server(
                Port,
                ?FUNCTION_NAME,
                0,
                fun() ->
                    with_pool(
                        Opts,
                        fun() -> req_async(200, timer:seconds(TestTimeout)) end
                    )
                end
            )
        end
    end,
    [
        {timeout, TestTimeout + 1, F(Opts2)},
        {timeout, TestTimeout + 1, F(Opts4)}
    ].

request_timeout_test_() ->
    [
        {"pipeline", fun() -> request_timeout_test(true) end},
        {"no pipeline", fun() -> request_timeout_test(false) end}
    ].

request_timeout_test(Pipeline) ->
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        300_000,
        fun() ->
            with_pool(
                pool_opts(Port, Pipeline),
                fun() ->
                    ?assertEqual(
                        {error, timeout},
                        req_sync_1(_Timeout = 1000)
                    )
                end
            )
        end
    ).

request_expire_test() ->
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        1_000,
        fun() ->
            with_pool(
                pool_opts(Port, true),
                fun() ->
                    Pid = spawn(fun() -> req_sync_1(_Timeout = 10_000) end),
                    {error, timeout} = req_sync_1(10),
                    exit(Pid, kill),
                    ok
                end
            )
        end
    ).

request_infinity_expire_sync_test() ->
    ct:timetrap({seconds, 10}),
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        1_000,
        fun() ->
            with_pool(
                pool_opts(Port, true),
                fun() ->
                    {ok, 200, _, _} = req_sync_1(infinity)
                end
            )
        end
    ).

request_infinity_expire_async_test() ->
    ct:timetrap({seconds, 10}),
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        1_000,
        fun() ->
            with_pool(
                pool_opts(Port, true),
                fun() -> req_async1(_Timeout = infinity) end
            )
        end
    ).

health_check_test_() ->
    Port = ?PORT,
    %% the normal case
    [
        {timeout, 20, fun() ->
            ?WITH(
                #{
                    port => Port,
                    name => ?FUNCTION_NAME,
                    delay => 0
                },
                pool_opts(Port, true),
                begin
                    Worker = ehttpc_pool:pick_worker(?POOL),
                    ?assertEqual(
                        ok,
                        ehttpc:health_check(Worker, 5_000)
                    )
                end
            )
        end},
        %% do health_check twice
        {timeout, 20, fun() ->
            ?WITH(
                #{
                    port => Port,
                    name => ?FUNCTION_NAME,
                    delay => 0
                },
                pool_opts(Port, true),
                begin
                    Worker = ehttpc_pool:pick_worker(?POOL),
                    ?assertEqual(
                        ok,
                        ehttpc:health_check(Worker, 5_000)
                    ),
                    ?assertEqual(
                        ok,
                        ehttpc:health_check(Worker, 5_000)
                    )
                end
            )
        end}
    ].

health_check_abnormal_test_() ->
    Port = ?PORT,
    Unreachable = "8.8.8.8",
    Unknown = "unknown-host0",
    [
        {timeout, 20,
            {"connect timeout", fun() ->
                ?WITH(
                    #{
                        port => Port,
                        name => ?FUNCTION_NAME,
                        delay => 0
                    },
                    pool_opts(Port, true),
                    begin
                        Worker = ehttpc_pool:pick_worker(?POOL),
                        %% 1. Do health_check with very short timeout,
                        %% The check failed but ehttpc is still trying to establish
                        %% the connection.
                        ?assertEqual(
                            {error, connect_timeout},
                            ehttpc:health_check(Worker, 0)
                        ),
                        %% 2. do health_check again should be OK.
                        ?assertEqual(ok, ehttpc:health_check(Worker, timer:seconds(2))),
                        {ok, _} = ?block_until(
                            #{?snk_kind := health_check_when_gun_client_not_ready},
                            1000,
                            infinity
                        )
                    end
                )
            end}},
        {timeout, 20,
            {"kill pool worker", fun() ->
                ?WITH(
                    #{
                        port => Port,
                        name => ?FUNCTION_NAME,
                        delay => 0
                    },
                    pool_opts(Port, true),
                    begin
                        Worker = ehttpc_pool:pick_worker(?POOL),
                        exit(Worker, kill),
                        ?assertMatch(
                            {error, {ehttpc_worker_down, _}},
                            ehttpc:health_check(Worker, 5_000)
                        )
                    end
                )
            end}},
        {timeout, 20,
            {"unreachable host", fun() ->
                ?WITH(
                    #{
                        port => Port,
                        name => ?FUNCTION_NAME,
                        delay => 0
                    },
                    pool_opts(Unreachable, Port, true),
                    begin
                        Worker = ehttpc_pool:pick_worker(?POOL),
                        ?assertEqual(
                            {error, connect_timeout},
                            ehttpc:health_check(Worker, 5_000)
                        )
                    end
                )
            end}},
        {timeout, 20,
            {"nxdomain", fun() ->
                ?WITH(
                    #{
                        port => Port,
                        name => ?FUNCTION_NAME,
                        delay => 0
                    },
                    pool_opts(Unknown, Port, true),
                    begin
                        Worker = ehttpc_pool:pick_worker(?POOL),
                        ?assertEqual(
                            {error, nxdomain},
                            ehttpc:health_check(Worker, 5_000)
                        )
                    end
                )
            end}}
    ].

server_outage_test_() ->
    Port = ?PORT,
    ServerName = ?FUNCTION_NAME,
    %% server delay for 5 seconds
    ServerDelay = 5_000,
    F =
        fun() ->
            %% spawn a process which will never get a 'ok' return
            %% because server delays for 5 seconds
            {Pid, Ref} = spawn_monitor(fun() -> exit(call(6_000)) end),
            {ok, _} = ?block_until(#{?snk_kind := shot}, 1000, infinity),
            {ok, #{pid := ServerPid}} = ?block_until(
                #{?snk_kind := ehttpc_server, delay := _}, 1000, infinity
            ),
            ServerPid ! close_socket,
            {ok, _} = ?block_until(#{?snk_kind := handle_client_down}, 1000, infinity),
            Res =
                receive
                    {'DOWN', Ref, process, Pid, ExitReason} ->
                        ExitReason
                after 3_000 ->
                    exit(timeout_waiting_for_gun_response)
                end,
            case Res of
                {error, {shutdown, closed}} ->
                    ok;
                {error, {closed, _}} ->
                    ok;
                Other ->
                    throw({unexpected_result, Other})
            end
        end,
    [
        {timeout, 20, fun() ->
            with_server(
                Port,
                ServerName,
                ServerDelay,
                fun() -> with_pool(pool_opts(Port, true), F) end
            )
        end},
        {timeout, 20, fun() ->
            with_server(
                Port,
                ServerName,
                ServerDelay,
                fun() -> with_pool(pool_opts(Port, false), F) end
            )
        end}
    ].

%% c:l(ehttpc) should work for version 0.1.8 -> 0.1.15
upgrade_state_on_the_fly_test() ->
    Port = ?PORT,
    ServerOpts = #{
        port => Port,
        name => ?FUNCTION_NAME,
        %% no response during this test
        delay => 300_000,
        oneoff => false
    },
    PoolOpts = pool_opts("127.0.0.1", Port, _Pipelining = true, _PrioritiseLatest = false),
    ?WITH(
        ServerOpts,
        PoolOpts,
        begin
            spawn_link(fun() -> ehttpc:request(?POOL, post, {<<"/">>, [], <<"test-post">>}) end),
            {ok, _} = ?block_until(#{?snk_kind := shot}, 2000, infinity),
            Pid = ehttpc_pool:pick_worker(?POOL),
            GetState = fun() -> sys:get_state(Pid) end,
            State = GetState(),
            RequestsIdx = 11,
            Requests = element(RequestsIdx, State),
            #{sent := Sent} = Requests,
            ?assertEqual(1, maps:size(Sent)),
            OldState = setelement(RequestsIdx, State, Sent),
            %% put old format to the process state
            sys:replace_state(Pid, fun(_) -> OldState end),
            %% verify it's in the old format
            ?assertEqual(Sent, element(RequestsIdx, GetState())),
            %% send a message to trigger upgrade
            Pid ! dummy,
            {error, _} = gen_server:call(Pid, dummy),
            ok = gen_server:cast(Pid, dummy),
            %% now it should be upgraded to the new version
            ?assertMatch(#{sent := Sent}, element(RequestsIdx, GetState())),
            _ = sys:get_status(Pid),
            ok
        end
    ).

cool_down_after_5_reqs_test() ->
    Port = ?PORT,
    ServerOpts = #{
        port => Port,
        name => ?FUNCTION_NAME,
        %% no response during this test
        delay => 30_000,
        oneoff => false
    },
    PoolOpts = pool_opts("127.0.0.1", Port, _Pipelining = 5, _PrioritiseLatest = false),
    Reqs = [{"/", [], iolist_to_binary(["test-put-", integer_to_list(I)])} || I <- lists:seq(1, 6)],
    ?WITH(
        ServerOpts,
        PoolOpts,
        begin
            lists:foreach(
                fun(Req) ->
                    spawn_link(fun() -> ehttpc:request(?POOL, put, {<<"/">>, [], Req}) end)
                end,
                Reqs
            ),
            {ok, _} = ?block_until(#{?snk_kind := cool_down}, 2000, infinity),
            Pid = ehttpc_pool:pick_worker(?POOL),
            #{requests := Requests} = ehttpc:get_state(Pid, normal),
            #{sent := Sent, pending_count := PendingCount} = Requests,
            ?assertEqual(5, maps:size(Sent)),
            ?assertEqual(1, PendingCount),
            ok
        end
    ).

head_request_test() ->
    Port = ?PORT,
    Host = "127.0.0.1",
    ?WITH(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 0
        },
        pool_opts(Host, Port, true),
        {ok, _, _} = ehttpc:request(?POOL, head, <<"/">>)
    ).

data_chunked_test() ->
    Port = ?PORT,
    Host = "127.0.0.1",
    ?WITH(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 0,
            chunked => #{
                delay => 10,
                %% 10ms delay between chunked response body parts
                chunk_size => 1 bsl 10,
                chunks => 2
            }
        },
        pool_opts(Host, Port, true),
        begin
            {ok, _, _, Body} = ehttpc:request(?POOL, get, req()),
            ?assertEqual(1 bsl 11, size(Body)),
            %% assert the order of the data
            %% ehttpc_server generates chunks like 11111111111....
            %% and 2222222.....
            ?assertEqual([1, 2], dedup(binary_to_list(Body)))
        end
    ).

data_chunk_timeout_test() ->
    Port = ?PORT,
    Host = "127.0.0.1",
    ?WITH(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 0,
            %% make the request
            chunked => #{
                delay => 10,
                chunk_size => 4096,
                chunks => 100
            }
        },
        pool_opts(Host, Port, _Pipelining = 2),
        ?assertEqual({error, timeout}, ehttpc:request(?POOL, get, req(), 200, 0))
    ).

connect_timeout_test() ->
    Port = ?PORT,
    Unreachable = "8.8.8.8",
    ?WITH(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 0
        },
        pool_opts(Unreachable, Port, true),
        ?assertEqual({error, connect_timeout}, req_sync_1(_Timeout = 200))
    ).

request_expire_2_test() ->
    Port = ?PORT,
    ServerDelay = timer:seconds(1),
    % the thrid request's timeout
    ReqTimeout3 = ServerDelay * 3,
    with_server(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            %% server delays one second before sending response
            delay => timer:seconds(1)
        },
        fun() ->
            with_pool(
                pool_opts(Port, false),
                fun() ->
                    %% this call will be blocked, and timeout after 200ms
                    spawn(fun() -> req_sync_1(200) end),
                    %% this call will be blocked, and expire after 200ms
                    ?assertEqual(
                        {error, timeout},
                        req_sync_1(_Timeout = 200)
                    ),
                    ?assertMatch({ok, 200, _, _}, req_sync_1(ReqTimeout3))
                end
            )
        end
    ).

request_expire_fin_too_late_test() ->
    Port = ?PORT,
    ServerFinDelay = timer:seconds(1),
    % the thrid request's timeout
    ReqTimeout3 = ServerFinDelay * 3,
    CallTimeout = 200,
    with_server(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 0,
            chunked => #{
                %% server delays one second before sending the last chunk
                fin_delay => ServerFinDelay,
                delay => 0,
                chunk_size => 1 bsl 10,
                chunks => 2
            }
        },
        fun() ->
            with_pool(
                pool_opts(Port, false),
                fun() ->
                    %% this call will be blocked, and timeout
                    spawn(fun() -> catch req_sync_1(CallTimeout) end),
                    %% this call will be blocked, and expire without actually sending the request
                    ?assertEqual(
                        {error, timeout},
                        req_sync_1(_Timeout = CallTimeout)
                    ),
                    ?assertMatch({ok, 200, _, _}, req_sync_1(ReqTimeout3))
                end
            )
        end,
        fun(_, Trace) ->
            %% assert one request dropped directly
            ?assertMatch([_], ?of_kind(drop_expired, Trace))
        end
    ).

hash_pool_test() ->
    Port1 = ?PORT,
    ServerOpts1 = #{port => Port1, name => ?FUNCTION_NAME, delay => {rand, 300}, oneoff => true},
    PoolOpts1 = put_pool_opts(pool_opts(Port1, false), pool_type, hash),
    Send = fun() ->
        ?assertMatch(
            {ok, 200, _, _},
            ehttpc:request({?POOL, self()}, get, req(), 1000, 0)
        )
    end,
    ?WITH(ServerOpts1, PoolOpts1, Send()).

with_server(Port, Name, Delay, F) ->
    ehttpc_test_lib:with_server(Port, Name, Delay, F).

with_server(Opts, F) ->
    ehttpc_test_lib:with_server(Opts, F).

with_server(Opts, F, CheckTrace) ->
    ehttpc_test_lib:with_server(Opts, F, CheckTrace).

req() -> {<<"/">>, [{<<"Connection">>, <<"Keep-Alive">>}]}.

req(N) -> {iolist_to_binary(["/", integer_to_list(N)]), [{<<"Connection">>, <<"Keep-Alive">>}]}.

req_sync_1(Timeout) ->
    ehttpc:request(?POOL, get, req(), Timeout, 0).

req_sync(N) ->
    req_sync(N, 5_000, 0).

req_sync(0, _Timeout, _Retry) ->
    ok;
req_sync(N, Timeout, Retry) ->
    case ehttpc:request(?POOL, get, req(), Timeout, Retry) of
        {ok, 200, _Headers, _Body} ->
            req_sync(N - 1, Timeout, Retry);
        {error, Reason} ->
            error({N, Reason})
    end.

req_async1(Timeout) ->
    Ref = make_ref(),
    TestPid = self(),
    ResultCallback = {fun(Reply) -> TestPid ! {{Ref, reply}, Reply} end, []},
    Method = get,
    Request = req(),
    ok = ehttpc:request_async(
        ehttpc_pool:pick_worker(?POOL), Method, Request, Timeout, ResultCallback
    ),
    receive
        {{Ref, reply}, Reply} ->
            {ok, 200, _, _} = Reply
    end.

req_async(N) ->
    req_async(N, 5_000).

req_async(N, Timeout) ->
    L = lists:seq(1, N),
    ehttpc_test_lib:parallel_map(
        fun(_) ->
            req_sync(1, Timeout, 0)
        end,
        L
    ).

pool_opts(Port, Pipeline) ->
    ehttpc_test_lib:pool_opts(Port, Pipeline).

pool_opts(Host, Port, Pipeline) ->
    ehttpc_test_lib:pool_opts(Host, Port, Pipeline).

pool_opts(Host, Port, Pipeline, PrioLatest) ->
    ehttpc_test_lib:pool_opts(Host, Port, Pipeline, PrioLatest).

put_pool_opts(Opts, Key, Value) ->
    [{Key, Value} | lists:keydelete(Key, 1, Opts)].

with_pool(Opts, F) ->
    ehttpc_test_lib:with_pool(?POOL, Opts, F).

call(Timeout) ->
    ehttpc:request(?POOL, get, req(), Timeout, 0).

dedup(L) ->
    dedup(hd(L), tl(L)).

dedup(H, []) -> [H];
dedup(H, [H | T]) -> dedup(H, T);
dedup(H, [X | T]) -> [H | dedup(X, T)].

%% Test case to check that requests are finished as they should be even when
%% there is no body and headers indicate that there should be a body. The gun
%% library handles this in a special way. See
%% https://ninenines.eu/docs/en/gun/1.3/manual/gun.data/ and
%% https://github.com/ninenines/gun/issues/141
no_body_but_headers_indicating_body_test_() ->
    snabbkaffe:fix_ct_logging(),
    Port = ?PORT,
    ServerOpts = #{port => Port, name => ?FUNCTION_NAME, oneoff => false},
    PoolOpts = pool_opts(Port, false),
    RequestsWithBody =
        fun() ->
            [
                begin
                    Response1 = ehttpc:request(
                        ?POOL,
                        RequestType,
                        {<<"/">>, [{<<"content-type">>, <<"text/html">>}], <<>>},
                        5000,
                        0
                    ),
                    ok = ensure_not_error_response(Response1),
                    Response2 = ehttpc:request(
                        ?POOL,
                        RequestType,
                        {<<"/">>, [{<<"content-length">>, <<"0">>}], <<>>},
                        5000,
                        0
                    ),
                    ok = ensure_not_error_response(Response2)
                end
             || RequestType <- [put, post, patch]
            ]
        end,
    RequestsWithNoBody =
        fun() ->
            [
                begin
                    Response1 = ehttpc:request(
                        ?POOL,
                        RequestType,
                        {<<"/">>, [{<<"content-type">>, <<"text/html">>}]},
                        5000,
                        0
                    ),
                    ok = ensure_not_error_response(Response1),
                    Response2 = ehttpc:request(
                        ?POOL,
                        RequestType,
                        {<<"/">>, [{<<"content-length">>, <<"0">>}]},
                        5000,
                        0
                    ),
                    ok = ensure_not_error_response(Response2)
                end
             || %% Extra get inthe end so all requests have a request comming after them.
                RequestType <- [get, delete, head, get]
            ]
        end,
    TestFunction =
        fun() ->
            RequestsWithBody(),
            RequestsWithNoBody()
        end,
    [
        fun() -> ?WITH(ServerOpts, PoolOpts, TestFunction()) end
    ].

gun_down_with_reason_normal_is_retried_test() ->
    Port = ?PORT,
    Host = "127.0.0.1",
    ok = snabbkaffe:start_trace(),
    with_server(
        #{
            port => Port,
            name => ?FUNCTION_NAME,
            delay => 1000
        },
        fun() ->
            ?WITH_POOL(
                pool_opts(Host, Port, _Pipelining = 2),
                begin
                    ?force_ordering(
                        #{?snk_kind := shot},
                        #{?snk_kind := will_disconnect}
                    ),
                    TestPid = self(),
                    spawn_link(fun() ->
                        ?tp(will_disconnect, #{}),
                        [
                            begin
                                Ref = monitor(process, P),
                                sys:terminate(P, normal),
                                receive
                                    {'DOWN', Ref, _, _, _} -> ok
                                after 500 -> ct:fail("gun didn't die")
                                end,
                                ok
                            end
                         || P <- processes(),
                            case proc_lib:initial_call(P) of
                                {gun, proc_lib_hack, _} -> true;
                                _ -> false
                            end
                        ],
                        ok
                    end),
                    spawn_link(fun() ->
                        Res = ehttpc:request(?POOL, get, req(), 2000, 0),
                        TestPid ! {result, Res}
                    end),
                    Res =
                        receive
                            {result, R} -> R
                        after 2_000 -> ct:fail("no response")
                        end,
                    ?assertMatch({ok, 200, _, _}, Res),
                    ok
                end
            )
        end,
        fun(Trace0) ->
            Trace = ?of_kind(
                [
                    gun_up,
                    shot,
                    handle_client_down,
                    ehttpc_retry_gun_down_normal
                ],
                Trace0
            ),
            ?assertMatch(
                %% first attempt
                [
                    gun_up,
                    shot,
                    handle_client_down,
                    %% we retry because of this particularly unusual race condition
                    ehttpc_retry_gun_down_normal,
                    gun_up,
                    shot
                ],
                ?projection(?snk_kind, Trace)
            ),
            ok
        end
    ),
    ok.

ensure_not_error_response({error, _Reason} = Error) ->
    Error;
ensure_not_error_response(_) ->
    ok.
