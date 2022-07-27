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

%% run some tests against google.com
-module(ehttpc_google_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POOL, ?MODULE).

-define(HOST, "google.com").
-define(PORT, 80).
-define(PATH, <<"/">>).
-define(METHOD, get).
-define(POOL_SIZE, 1).

concurrent_callers_test_() ->
    N = 1000,
    TestTimeout = 10,
    Host = ?HOST,
    Port = ?PORT,
    %%                host  port  enable_pipelining prioritise_latest
    Opts1 = pool_opts(Host, Port, true, true),
    Opts2 = pool_opts(Host, Port, true, false),
    Opts3 = pool_opts(Host, Port, false, true),
    Opts4 = pool_opts(Host, Port, false, false),
    F = fun() -> req_async(?METHOD, N) end,
    [
        {timeout, TestTimeout, fun() -> with_pool(Opts1, F) end},
        {timeout, TestTimeout, fun() -> with_pool(Opts2, F) end},
        {timeout, TestTimeout, fun() -> with_pool(Opts3, F) end},
        {timeout, TestTimeout, fun() -> with_pool(Opts4, F) end}
    ].

req(get) ->
    {?PATH, [{<<"Connection">>, <<"Keep-Alive">>}]};
req(post) ->
    {?PATH, [{<<"Connection">>, <<"Keep-Alive">>}],
        term_to_binary(io_lib:format("~0p: ~0p~n", [erlang:system_time(), self()]))}.

req_sync(_Method, 0, _Timeout) ->
    ok;
req_sync(Method, N, Timeout) ->
    case ehttpc:request(?POOL, Method, req(Method), Timeout, _Retry = 0) of
        {ok, _, _Headers, _Body} -> ok;
        {error, timeout} -> timeout
    end,
    req_sync(Method, N - 1, Timeout).

req_async(Method, N) ->
    {Time, Results} = timer:tc(fun() -> req_async(Method, N, 5_000) end),
    {OK, Timeout} = lists:partition(fun(I) -> I =:= ok end, Results),
    io:format(
        user,
        "~n============~ntime: ~p OKs: ~p Timeouts ~p~n",
        [Time, length(OK), length(Timeout)]
    ).

req_async(Method, N, Timeout) ->
    L = lists:seq(1, N),
    ehttpc_test_lib:parallel_map(
        fun(_) ->
            req_sync(Method, 1, Timeout)
        end,
        L
    ).

pool_opts(Host, Port, Pipeline, PrioLatest) ->
    [
        {host, Host},
        {port, Port},
        {enable_pipelining, Pipeline},
        {pool_size, ?POOL_SIZE},
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
