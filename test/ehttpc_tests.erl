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

-define(POOL, ?MODULE).
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
    ServerOpts2 = #{port => Port, name => ?FUNCTION_NAME, delay => {rand, 300}, oneoff => false},
    PoolOpts1 = pool_opts(Port, false),
    PoolOpts2 = pool_opts(Port, true),
    [
        %% allow one retry for oneoff=true server, because of the 'DOWN' message race
        {"oneoff=true", fun() -> ?WITH(ServerOpts1, PoolOpts1, req_sync(100, 1000, 1)) end},
        {"oneoff=false", fun() -> ?WITH(ServerOpts2, PoolOpts2, req_async(100)) end}
    ].

send_1000_test_() ->
    TestTimeout = 30,
    Port = ?PORT,
    Opts1 = pool_opts(Port, true),
    Opts2 = pool_opts(Port, false),
    Opts3 = pool_opts("localhost", Port, true, true),
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
                        fun() -> req_async(1000, timer:seconds(TestTimeout)) end
                    )
                end
            )
        end
    end,
    [
        {timeout, TestTimeout + 1, F(Opts1)},
        {timeout, TestTimeout + 1, F(Opts2)},
        {timeout, TestTimeout + 1, F(Opts3)},
        {timeout, TestTimeout + 1, F(Opts4)}
    ].

requst_timeout_test_() ->
    [
        {"pipeline", fun() -> requst_timeout_test(true) end},
        {"no pipeline", fun() -> requst_timeout_test(false) end}
    ].

requst_timeout_test(Pipeline) ->
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

requst_expire_test() ->
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
                    exit(Worker, kill),
                    ?assertMatch(
                        {error, {ehttpc_worker_down, _}},
                        ehttpc:health_check(Worker, 5_000)
                    )
                end
            )
        end},
        {timeout, 20, fun() ->
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
        end},
        {timeout, 20, fun() ->
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
        end},
        {timeout, 20, fun() ->
            ?WITH(
                #{
                    port => Port,
                    name => ?FUNCTION_NAME,
                    delay => 0
                },
                [
                    {host, "127.0.0.1"},
                    {port, ?PORT},
                    {pool_size, 1},
                    {pool_type, random},
                    {connect_timeout, invalid_val}
                ],
                begin
                    Worker = ehttpc_pool:pick_worker(?POOL),
                    ?assertEqual(
                        {error, {options, {connect_timeout, invalid_val}}},
                        ehttpc:health_check(Worker, 5_000)
                    )
                end
            )
        end}
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
                    Worker = ehttpc_pool:pick_worker(?POOL),
                    io:format(user, "~p\n", [sys:get_state(Worker)]),
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
            GetState = fun() -> lists:reverse(tuple_to_list(sys:get_state(Pid))) end,
            State = GetState(),
            Requests = hd(State),
            #{sent := Sent} = Requests,
            ?assertEqual(1, maps:size(Sent)),
            OldState = list_to_tuple(lists:reverse([Sent | tl(State)])),
            %% put old format to the process state
            sys:replace_state(Pid, fun(_) -> OldState end),
            %% verify it's in the old format
            ?assertEqual(Sent, hd(GetState())),
            %% send a message to trigger upgrade
            Pid ! dummy,
            {error, _} = gen_server:call(Pid, dummy),
            ok = gen_server:cast(Pid, dummy),
            %% now it should be upgraded to the new version
            ?assertMatch(#{sent := Sent}, hd(GetState())),
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

request_expire_test() ->
    Port = ?PORT,
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
                    )
                end
            )
        end
    ).

with_server(Port, Name, Delay, F) ->
    Opts = #{port => Port, name => Name, delay => Delay},
    with_server(Opts, F).

with_server(Opts, F) ->
    ?check_trace(
        begin
            Pid = ehttpc_server:start_link(Opts),
            try
                {ok, _} =
                    ?block_until(
                        #{
                            ?snk_kind := ehttpc_server,
                            state := accepting
                        },
                        2_000,
                        infinity
                    ),
                F()
            after
                ehttpc_server:stop(Pid)
            end
        end,
        []
    ).

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
    pool_opts("127.0.0.1", Port, Pipeline).

pool_opts(Host, Port, Pipeline) ->
    pool_opts(Host, Port, Pipeline, false).

pool_opts(Host, Port, Pipeline, PrioLatest) ->
    [
        {host, Host},
        {port, Port},
        {enable_pipelining, Pipeline},
        {pool_size, 1},
        {pool_type, random},
        {connect_timeout, 5000},
        {prioritise_latest, PrioLatest}
    ].

with_pool(Opts, F) ->
    application:ensure_all_started(ehttpc),
    try
        {ok, _} = ehttpc_sup:start_pool(?POOL, Opts),
        F()
    after
        ehttpc_sup:stop_pool(?POOL)
    end.

call(Timeout) ->
    ehttpc:request(?POOL, get, req(), Timeout, 0).

dedup(L) ->
    dedup(hd(L), tl(L)).

dedup(H, []) -> [H];
dedup(H, [H | T]) -> dedup(H, T);
dedup(H, [X | T]) -> [H | dedup(X, T)].
