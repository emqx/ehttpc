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
-export([ start_pool/2
        , stop_pool/1
        ]).

%% Supervisor callbacks
-export([init/1]).

%% @doc Start supervisor.
-spec(start_link() -> {ok, pid()} | {error, term()}).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% Start/Stop a pool
%%--------------------------------------------------------------------

%% @doc Start a pool.
-spec(start_pool(atom(), list(tuple())) -> {ok, pid()} | {error, term()}).
start_pool(Pool, Opts) when is_atom(Pool) ->
    supervisor:start_child(?MODULE, pool_spec(Pool, Opts)).

%% @doc Stop a pool.
-spec(stop_pool(Pool :: atom()) -> ok | {error, term()}).
stop_pool(Pool) when is_atom(Pool) ->
    ChildId = child_id(Pool),
	case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            supervisor:delete_child(?MODULE, ChildId);
        {error, Reason} ->
            {error, Reason}
	end.

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, { {one_for_one, 10, 100}, []} }.

pool_spec(Pool, Opts) ->
    #{id => child_id(Pool),
      start => {ehttpc_pool_sup, start_link, [Pool, Opts]},
      restart => transient,
      shutdown => infinity,
      type => supervisor,
      modules => [ehttpc_pool_sup]}.

child_id(Pool) -> {ehttpc_pool_sup, Pool}.

