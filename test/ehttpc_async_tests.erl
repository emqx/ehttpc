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

-module(ehttpc_async_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(POOL, ?MODULE).
-define(PORT, (65000 + ?LINE)).

-define(WITH_SERVER(Opts, Expr),
    with_server(Opts, fun() -> Expr end)
).
-define(WITH_POOL(PoolOpts, Expr),
    with_pool(PoolOpts, fun() -> Expr end)
).

-define(WITH(ServerOpts, PoolOpts, Expr),
    ?WITH_SERVER(ServerOpts, ?WITH_POOL(PoolOpts, Expr))
).

send_10_sync_test_() ->
    Port = ?PORT,
    ServerOpts = #{port => Port, name => ?FUNCTION_NAME, delay => {rand, 300}, oneoff => false},
    PoolOpts = pool_opts(Port, false),
    {"oneoff=false", fun() -> ?WITH(ServerOpts, PoolOpts, req_sync(10)) end}.

send_10_async_test() ->
    Port = ?PORT,
    ServerOpts = #{port => Port, name => ?FUNCTION_NAME, delay => {rand, 30}, oneoff => false},
    PoolOpts = pool_opts(Port, false),
    true = ?WITH(ServerOpts, PoolOpts, req_async(10, 1000)).

no_expired_req_send_test() ->
    Port = ?PORT,
    % infinity
    ServerDelay = 10000000,
    ServerOpts = #{port => Port, name => ?FUNCTION_NAME, delay => ServerDelay, oneoff => false},
    PoolOpts = pool_opts(Port, _Pipelining = 1),
    TimeoutMs = 10,
    ?WITH(
        ServerOpts,
        PoolOpts,
        begin
            %% send one, this will block the http stream, causing all the subsequent ones to timeout
            [_] = send_reqs(1, TimeoutMs),
            Refs = send_reqs(10, TimeoutMs),
            Pid = ehttpc_pool:pick_worker(?POOL),
            %% ensure all the requests are queued
            ok = ehttpc:health_check(Pid, 100),
            %% send another one after a delay, this will trigger ehttpc worker to drop all expired requests and reply {error, timeout}
            timer:sleep(TimeoutMs),
            [_] = send_reqs(1, TimeoutMs + 10),
            lists:foreach(
                fun(Ref) ->
                    ?assertEqual({error, timeout}, await_reply(Ref, TimeoutMs))
                end,
                Refs
            )
        end
    ).

with_pool(Opts, F) ->
    ehttpc_test_lib:with_pool(?POOL, Opts, F).

pool_opts(Port, Pipeline) ->
    ehttpc_test_lib:pool_opts(Port, Pipeline).

with_server(Opts, F) ->
    true = ehttpc_test_lib:with_server(Opts, F).

req_async(N, Timeout) ->
    %% send N async requests
    Refs = send_reqs(N, Timeout),
    %% collect N async results
    lists:foreach(
        fun(Ref) ->
            case await_reply(Ref, Timeout) of
                {ok, 200, _Headers, _Body} ->
                    ok;
                {error, Reason} ->
                    error(Reason)
            end
        end,
        Refs
    ).

send_reqs(N, Timeout) ->
    lists:map(
        fun(_I) ->
            {ok, Ref} = request_async(get, req(), Timeout),
            Ref
        end,
        lists:seq(1, N)
    ).

req_sync(N) ->
    req_sync(N, 5_000).

req_sync(0, _Timeout) ->
    ok;
req_sync(N, Timeout) ->
    case request_sync(get, req(), Timeout) of
        {ok, 200, _Headers, _Body} ->
            req_sync(N - 1, Timeout);
        {error, Reason} ->
            error({N, Reason})
    end.

req() -> {<<"/">>, [{<<"Connection">>, <<"Keep-Alive">>}]}.

request_sync(Method, Req, Timeout) ->
    {ok, Ref} = request_async(Method, Req, Timeout),
    await_reply(Ref, Timeout).

await_reply(Ref, Timeout) ->
    receive
        {Ref, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, _, Reason} ->
            {error, {pool_worker_down, Reason}}
    after Timeout + 2000 ->
        error(await_reply_timeout)
    end.

request_async(Method, Req, Timeout) ->
    Caller = self(),
    Pid = ehttpc_pool:pick_worker(?POOL),
    Ref = erlang:monitor(process, Pid),
    Callback = {fun(Result) -> Caller ! {Ref, Result} end, []},
    ok = ehttpc:request_async(Pid, Method, Req, Timeout, Callback),
    {ok, Ref}.
