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

%% First version used in EMQX v4.3.0
-record(state_0_1_0, {pool, id, client, mref, host, port, gun_opts, gun_state}).
-record(state_0_1_7, {pool, id, client, mref, host, port, gun_opts, gun_state, requests}).
-record(state_0_1_8, {
    pool, id, client, mref, host, port, enable_pipelining, gun_opts, gun_state, requests
}).

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

ensuer_changelog_test() ->
    {ok, [{application, ehttpc, Props}]} = file:consult("src/ehttpc.app.src"),
    Vsn = proplists:get_value(vsn, Props),
    ExpectedChangeLogLine = "## " ++ Vsn,
    {ok, Text} = file:read_file("changelog.md"),
    Lines = binary:split(Text, <<"\n">>, [global]),
    case lists:member(iolist_to_binary(ExpectedChangeLogLine), Lines) of
        true -> ok;
        false -> error({missing_changelog_for_vsn, ExpectedChangeLogLine})
    end.

ensure_version_bump_test() ->
    Latest = lists:last(lists:sort([parse_semver(T) || T <- all_tags()])),
    LatestTag = format_semver(Latest),
    ChangedFiles = os:cmd("git diff --name-only " ++ LatestTag ++ "...HEAD src"),
    case ChangedFiles of
        [] ->
            ok;
        Other ->
            io:format(user, "~nchanged since ~s:~n~p~n", [LatestTag, Other]),
            error(need_version_bump)
    end.

format_semver({Major, Minor, Patch}) ->
    lists:flatten(io_lib:format("~p.~p.~p", [Major, Minor, Patch])).

parse_semver(Str) ->
    [Major, Minor, Patch | _] = string:tokens(Str, ".-\n"),
    {list_to_integer(Major), list_to_integer(Minor), list_to_integer(Patch)}.

all_tags() ->
    string:tokens(os:cmd("git tag"), "\n").

git_tag_match_upgrade_vsn_test_() ->
    {ok, [{AppupVsn, Upgraes, Downgrades}]} = file:consult("src/ehttpc.appup.src"),
    [
        {Tag, fun() -> true = has_a_match(Tag, Upgraes, Downgrades) end}
     || Tag <- all_tags(), Tag =/= AppupVsn
    ].

has_a_match(Tag, Ups, Downs) ->
    has_a_match(Tag, Ups) andalso
        has_a_match(Tag, Downs).

has_a_match(_, []) ->
    false;
has_a_match(Tag, [{Tag, _} | _]) ->
    true;
has_a_match(Tag, [{Tag1, _} | Rest]) when is_list(Tag1) ->
    has_a_match(Tag, Rest);
has_a_match(Tag, [{Re, _} | Rest]) when is_binary(Re) ->
    case re:run(Tag, Re, [unicode, {capture, first, list}]) of
        {match, [Tag]} -> true;
        _ -> has_a_match(Tag, Rest)
    end.

%% NOTE: the git tag 0.1.0 was re-tagged
upgrade_from_test_() ->
    Old1 = #state_0_1_0{mref = make_ref()},
    Old2 = #state_0_1_7{mref = make_ref(), requests = #{}},
    Old3 = #state_0_1_8{mref = make_ref(), requests = #{}},
    F = fun({Old, Extra}) ->
        {ok, New} = ehttpc:code_change("old", new_tag(Old), []),
        #{requests := Requests} = ehttpc:format_state(New, normal),
        ?assertMatch(
            #{
                pending := _,
                pending_count := 0,
                sent := #{}
            },
            Requests
        ),
        {ok, Down} = ehttpc:code_change({down, "new"}, New, Extra),
        OldTag = element(1, Old),
        ?assertEqual(Old, old_tag(OldTag, Down))
    end,
    [
        {atom_to_list(element(1, Old)), fun() -> F({Old, Extra}) end}
     || {Old, Extra} <- [
            {Old1, [no_requests]},
            {Old2, [no_enable_pipelining]},
            {Old3, [downgrade_requests]}
        ]
    ].

old_tag(Tag, State) ->
    setelement(1, State, Tag).

new_tag(State) ->
    setelement(1, State, state).

upgrade_requests_test() ->
    Old = #{foo => bar},
    New = ehttpc:upgrade_requests(Old),
    ?assertMatch(
        #{
            sent := Old,
            pending := _,
            pending_count := 0
        },
        New
    ),
    ?assertMatch(Old, ehttpc:downgrade_requests(New)).
