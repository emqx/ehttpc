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

-define(POOL, ?MODULE).


shutdown_test_() ->
    [ {timeout, 10, fun t_shutdown/0}
    ].

t_shutdown() ->
    Opts = [ {host, "google.com"},
             {port, "80"},
             {enable_pipelining, 1},
             {pool_size, 1},
             {pool_type, random},
             {connect_timeout, 5000},
             {prioritise_latest, true}
           ],
    application:ensure_all_started(ehttpc),
    {ok, SupPid} = ehttpc_sup:start_pool(?POOL, Opts),
    unlink(SupPid),
    _ = monitor(process, SupPid),
    try
        Worker = ehttpc_pool:pick_worker(?POOL),
        _ = monitor(process, Worker),
        _ = sys:get_state(Worker),
        %% suspend (zombie-fy) the (one and only) worker
        Worker ! {suspend, timer:seconds(60)},
        %% zombie worker should not block pool stop
        ok = ehttpc_sup:stop_pool(?POOL),
        receive
            {'DOWN', _, process, SupPid, killed} ->
                ok;
            Other2 ->
                ct:fail({"unexpected_message", Other2})
        after 6000 ->
                  ct:fail("failed_to_stop_pool_supervisor")
        end,
        receive
            {'DOWN', _, process, Worker, killed} ->
                ok;
            Other ->
                ct:fail({"unexpected_message", Other})
        after 1000 ->
                  ct:fail("failed_to_stop_worker_from_sup_shutdown")
        end
    after
        exit(SupPid, kill)
    end.
