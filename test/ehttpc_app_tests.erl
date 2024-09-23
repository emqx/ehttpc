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

-module(ehttpc_app_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_vsn_bump_test() ->
    TagV = parse_semver(os:cmd("git describe --tags")),
    {ok, [{application, ehttpc, Props}]} = file:consult("src/ehttpc.app.src"),
    V = parse_semver(proplists:get_value(vsn, Props)),
    ?assert(TagV =< V).

ensure_changelog_test() ->
    {ok, [{application, ehttpc, Props}]} = file:consult("src/ehttpc.app.src"),
    Vsn = proplists:get_value(vsn, Props),
    ExpectedChangeLogLine = "## " ++ Vsn,
    {ok, Text} = file:read_file("changelog.md"),
    Lines = binary:split(Text, <<"\n">>, [global]),
    case lists:member(iolist_to_binary(ExpectedChangeLogLine), Lines) of
        true -> ok;
        false -> error({missing_changelog_for_vsn, ExpectedChangeLogLine})
    end.

ensure_git_tag_test() ->
    Latest = lists:last(lists:sort([parse_semver(T) || T <- all_tags()])),
    LatestTag = format_semver(Latest),
    ChangedFiles = os:cmd("git diff --name-only " ++ LatestTag ++ "...HEAD src"),
    case ChangedFiles of
        [] ->
            ok;
        Other ->
            %% only print a warning message
            %% because we can not control git tags in eunit
            io:format(
                user,
                "################################~n"
                "changed since ~s:~n~p~n",
                [LatestTag, Other]
            ),
            ok
    end.

format_semver({Major, Minor, Patch}) ->
    lists:flatten(io_lib:format("~p.~p.~p", [Major, Minor, Patch])).

parse_semver(Str) ->
    [Major, Minor, Patch | _] = string:tokens(Str, ".-\n"),
    {list_to_integer(Major), list_to_integer(Minor), list_to_integer(Patch)}.

all_tags() ->
    string:tokens(os:cmd("git tag"), "\n").
