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

-module(ehttpc_sup_tests).

-include_lib("eunit/include/eunit.hrl").

shutdown_test_() ->
    [{timeout, 10, fun t_shutdown/0}].

t_shutdown() ->
    Pool = atom_to_binary(?MODULE),
    Opts = [
        {host, "google.com"},
        {port, "80"},
        {enable_pipelining, 1},
        {pool_size, 1},
        {pool_type, random},
        {connect_timeout, 5000},
        {prioritise_latest, true}
    ],
    application:ensure_all_started(ehttpc),
    {ok, SupPid} = ehttpc_sup:start_pool(Pool, Opts),
    unlink(SupPid),
    _ = monitor(process, SupPid),
    Worker = ehttpc_pool:pick_worker(Pool),
    try
        _ = monitor(process, Worker),
        _ = sys:get_state(Worker),
        %% suspend (zombie-fy) the (one and only) worker
        Worker ! {suspend, timer:seconds(60)},
        %% zombie worker should not block pool stop
        ok = ehttpc_sup:stop_pool(Pool),
        ok = wait_for_down([SupPid, Worker])
    after
        exit(SupPid, kill),
        exit(Worker, kill)
    end.

wait_for_down([]) ->
    ok;
wait_for_down(Pids) ->
    receive
        {'DOWN', _, process, Pid, killed} ->
            wait_for_down(Pids -- [Pid])
    after 10_000 ->
        error(timeout)
    end.
