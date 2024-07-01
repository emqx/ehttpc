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

-module(ehttpc_pool_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(PORT, (60000 + ?LINE)).

kill_recover_test_() ->
    {
        setup,
        fun() -> application:ensure_all_started(ehttpc) end,
        fun(_) -> application:stop(ehttpc) end,
        {timeout, 10, fun test_kill_recover/0}
    }.

test_kill_recover() ->
    Pool = ?FUNCTION_NAME,
    Port = ?PORT,
    ehttpc_test_lib:with_server(#{name => ?FUNCTION_NAME, port => Port}, fun() ->
        {ok, SupPid} = ehttpc_sup:start_pool(Pool, [
            {host, "127.0.0.1"},
            {port, Port}
        ]),
        ?assertMatch(
            {ok, 200, _, _},
            ehttpc:request(Pool, get, {<<"/">>, []}, 1000, 0)
        ),
        PoolPid = pick_sup_child(pool, SupPid),
        true = erlang:exit(PoolPid, kill),
        %% Wait for the pool to restart pool owner process and recover.
        ?retry(
            100,
            10,
            ?assertMatch(P when is_pid(P) andalso P =/= PoolPid, pick_sup_child(pool, SupPid))
        ),
        %% Are things still work?
        ?assertMatch(
            {ok, 200, _, _},
            ehttpc:request(Pool, get, {<<"/">>, []}, 1000, 0)
        ),
        %% Stop the pool
        ehttpc_pool:stop_pool(Pool)
    end).

pick_sup_child(Id, SupPid) ->
    SupChildren = supervisor:which_children(SupPid),
    ?assert(lists:keymember(Id, 1, SupChildren), SupChildren),
    {Id, Pid, _, _} = lists:keyfind(Id, 1, SupChildren),
    Pid.
