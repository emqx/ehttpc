%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(ehttpc_appup_tests).

-include_lib("eunit/include/eunit.hrl").

app_vsn_test() ->
    {ok, [{AppupVsn, _Upgraes, _Downgrades}]} = file:consult("src/ehttpc.appup.src"),
    {ok, [{application, ehttpc, Props}]} = file:consult("src/ehttpc.app.src"),
    Vsn = proplists:get_value(vsn, Props),
    ?assertEqual(Vsn, AppupVsn).

ensure_vsn_bump_test() ->
    TagV = parse_semver(os:cmd("git describe --tags")),
    {ok, [{application, ehttpc, Props}]} = file:consult("src/ehttpc.app.src"),
    V = parse_semver(proplists:get_value(vsn, Props)),
    ?assert(TagV =< V).

parse_semver(Str) ->
    [Major, Minor, Patch | _] = string:tokens(Str, ".-"),
    {list_to_integer(Major), list_to_integer(Minor), list_to_integer(Patch)}.
