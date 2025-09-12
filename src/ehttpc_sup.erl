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

-module(ehttpc_sup).

-behaviour(supervisor).

-export([start_link/0]).

%% API
-export([
    start_pool/2,
    stop_pool/1,
    check_pool_integrity/1
]).

%% Supervisor callbacks
-export([init/1]).

%% @doc Start supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec check_pool_integrity(ehttpc:pool_name()) ->
    ok | {error, {processes_down, [root | pool | worker_sup]} | not_found}.
check_pool_integrity(Pool) ->
    case get_child(child_id(Pool)) of
        {ok, SupPid} ->
            do_check_pool_integrity_root(SupPid);
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% Start/Stop a pool
%%--------------------------------------------------------------------

%% @doc Start a pool.
-spec start_pool(ehttpc:pool_name(), list(tuple())) -> {ok, pid()} | {error, term()}.
start_pool(Pool, Opts) ->
    supervisor:start_child(?MODULE, pool_spec(Pool, Opts)).

%% @doc Stop a pool.
-spec stop_pool(Pool :: ehttpc:pool_name()) -> ok | {error, term()}.
stop_pool(Pool) ->
    ChildId = child_id(Pool),
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            supervisor:delete_child(?MODULE, ChildId);
        {error, not_found} ->
            ok
    end.

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 10, 100}, []}}.

pool_spec(Pool, Opts) ->
    #{
        id => child_id(Pool),
        start => {ehttpc_pool_sup, start_link, [Pool, Opts]},
        restart => transient,
        shutdown => 5000,
        type => supervisor,
        modules => [ehttpc_pool_sup]
    }.

child_id(Pool) -> {ehttpc_pool_sup, Pool}.

%%--------------------------------------------------------------------
%% Internal fns
%%--------------------------------------------------------------------

get_child(Id) ->
    Res = [Child || {Id0, Child, supervisor, _} <- supervisor:which_children(?MODULE), Id == Id0],
    case Res of
        [] ->
            {error, not_found};
        [undefined] ->
            {error, dead};
        [restarting] ->
            {error, restarting};
        [Pid] when is_pid(Pid) ->
            {ok, Pid}
    end.

do_check_pool_integrity_root(SupPid) ->
    try supervisor:which_children(SupPid) of
        Children ->
            %% We ignore `restarting` here because those processes are still being
            %% managed.
            DeadChildren = [Id || {Id, undefined, _, _} <- Children],
            %% Currently, at root, we only have one supervisor: `ehttpc_worker_sup`, and
            %% it does not contain other supervisors under it, so no need to dig deeper.
            case DeadChildren of
                [_ | _] ->
                    {error, {processes_down, DeadChildren}};
                [] ->
                    ok
            end
    catch
        exit:{noproc, _} ->
            {error, {processes_down, [root]}}
    end.
