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

-module(ehttpc_pool).

-behaviour(gen_server).

%% API Function Exports
-export([start_link/2]).

-export([
    info/1,
    start_pool/2,
    stop_pool/1,
    pick_worker/1,
    pick_worker/2
]).

%% gen_server Function Exports
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-import(proplists, [get_value/3]).

-record(state, {name, size, type}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link(ehttpc:pool_name(), list(ehttpc:option())) ->
    {ok, pid()} | {error, term()}.
start_link(Pool, Opts) ->
    gen_server:start_link(?MODULE, [Pool, Opts], []).

-spec info(pid()) -> list().
info(Pid) ->
    gen_server:call(Pid, info).

start_pool(Pool, Opts) ->
    ehttpc_sup:start_pool(Pool, Opts).

stop_pool(Pool) ->
    ehttpc_sup:stop_pool(Pool).

pick_worker(Pool) ->
    gproc_pool:pick_worker(ehttpc:name(Pool)).

pick_worker(Pool, Value) ->
    gproc_pool:pick_worker(ehttpc:name(Pool), Value).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Pool, Opts]) ->
    process_flag(trap_exit, true),
    Schedulers = erlang:system_info(schedulers),
    PoolSize = get_value(pool_size, Opts, Schedulers),
    PoolType = get_value(pool_type, Opts, random),
    ok = ensure_pool(Pool, PoolType, [{size, PoolSize}]),
    ok = lists:foreach(
        fun(I) ->
            add_pool_worker(Pool, {Pool, I}, I)
        end,
        lists:seq(1, PoolSize)
    ),
    {ok, #state{name = Pool, size = PoolSize, type = PoolType}}.

handle_call(info, _From, State = #state{name = Pool, size = Size, type = Type}) ->
    Workers = ehttpc:workers(Pool),
    Info = [
        {pool_name, Pool},
        {pool_size, Size},
        {pool_type, Type},
        {workers, Workers}
    ],
    {reply, Info, State};
handle_call(Req, _From, State) ->
    logger:error("[Pool] unexpected request: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    logger:error("[Pool] unexpected msg: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    logger:error("[Pool] unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{name = Pool}) ->
    delete_pool(Pool).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

ensure_pool(Pool, Type, Opts) ->
    try
        create_pool(Pool, Type, Opts)
    catch
        error:exists ->
            delete_pool(Pool),
            create_pool(Pool, Type, Opts)
    end.

add_pool_worker(Pool, Name, Slot) ->
    gproc_pool:add_worker(ehttpc:name(Pool), Name, Slot).

create_pool(Pool, Type, Opts) ->
    gproc_pool:new(ehttpc:name(Pool), Type, Opts).

delete_pool(Pool) ->
    gproc_pool:force_delete(ehttpc:name(Pool)).
