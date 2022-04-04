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

-define(POOL, ?MODULE).
-define(PORT, (60000 + ?LINE)).

send_10_test() ->
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        {rand, 300},
        fun() ->
            with_pool(
                pool_opts(Port, false),
                fun() -> req_sync(10) end
            )
        end
    ).

send_100_test() ->
    Port = ?PORT,
    with_server(
        Port,
        ?FUNCTION_NAME,
        {rand, 300},
        fun() ->
            with_pool(
                pool_opts(Port, true),
                fun() -> req_async(100) end
            )
        end
    ).

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
    ?assertEqual(
        {error, timeout},
        with_server(
            Port,
            ?FUNCTION_NAME,
            300_000,
            fun() ->
                with_pool(
                    pool_opts(Port, Pipeline),
                    fun() -> req_sync_1(_Timeout = 1) end
                )
            end
        )
    ).

requst_expire_test() ->
    Port = ?PORT,
    ?assertEqual(
        ok,
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
        )
    ).

server_outage_test_() ->
    Port = ?PORT,
    ServerName = ?FUNCTION_NAME,
    ServerDelay = 300_000,
    F =
        fun() ->
            %% ensure gun is connected to server
            {error, timeout} = call(100),
            %% now spawn a process which will never get a return value
            {Pid, Ref} = spawn_monitor(fun() -> exit({return, call(100_000)}) end),
            ServerPid = whereis(ServerName),
            ServerMref = monitor(process, ServerPid),
            ServerPid ! stop,
            receive
                {'DOWN', ServerMref, process, _, _} ->
                    io:format(user, "http_server_down...", [])
            after 1000 ->
                exit(timeout_kill_server)
            end,
            Res =
                receive
                    {'DOWN', Ref, process, Pid, ExitReason} ->
                        ExitReason
                after 100_000 ->
                    Worker = ehttpc_pool:pick_worker(?POOL),
                    io:format(user, "~p\n", [sys:get_state(Worker)]),
                    exit(timeout_waiting_for_gun_response)
                end,
            ?assertMatch({return, {error, {shutdown, _Closed}}}, Res)
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

connect_timeout_test() ->
    Port = ?PORT,
    ?assertEqual(
        {error, connect_timeout},
        with_server(
            #{
                port => Port,
                name => ?FUNCTION_NAME,
                delay => 0
            },
            fun() ->
                Unreachable = "4.4.4.4",
                with_pool(
                    pool_opts(Unreachable, Port, true),
                    fun() -> req_sync_1(_Timeout = 200) end
                )
            end
        )
    ).

request_expire_test() ->
    Port = ?PORT,
    ?assertEqual(
        {error, timeout},
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
                        req_sync_1(_Timeout = 200)
                    end
                )
            end
        )
    ).

with_server(Port, Name, Delay, F) ->
    Opts = #{port => Port, name => Name, delay => Delay},
    with_server(Opts, F).

with_server(Opts, F) ->
    Pid = ehttpc_server:start_link(Opts),
    try
        F()
    after
        ehttpc_server:stop(Pid)
    end.

req() -> {<<"/">>, [{<<"Connection">>, <<"Keep-Alive">>}]}.

req_sync_1(Timeout) ->
    ehttpc:request(?POOL, get, req(), Timeout).

req_sync(N) ->
    req_sync(N, 5_000).

req_sync(0, _Timeout) ->
    ok;
req_sync(N, Timeout) ->
    {ok, 200, _Headers, _Body} =
        ehttpc:request(?POOL, get, req(), Timeout),
    req_sync(N - 1).

req_async(N) ->
    req_async(N, 5_000).

req_async(N, Timeout) ->
    L = lists:seq(1, N),
    ehttpc_test_lib:parallel_map(
        fun(_) ->
            req_sync(1, Timeout)
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
        {retry, 0},
        {retry_timeout, 1000},
        {prioritise_latest, PrioLatest}
    ].

with_pool(Opts, F) ->
    application:ensure_all_started(ehttpc),
    {ok, _} = ehttpc_sup:start_pool(?POOL, Opts),
    try
        F()
    after
        ehttpc_sup:stop_pool(?POOL)
    end.

call(Timeout) ->
    ehttpc:request(?POOL, get, req(), Timeout).
