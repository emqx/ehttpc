%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(ehttpc_tests).

-include_lib("eunit/include/eunit.hrl").

maybe_ipv6_test_() ->
    [ { "user defined v4",
        fun() ->
                Opts = #{transport_opts => [inet6, foo]},
                ?assertEqual(Opts, maybe_ipv6(dummy, dummy, Opts))
        end
      }
    , { "user defined v6",
        fun() ->
                Opts = #{transport_opts => [inet6, foo]},
                ?assertEqual(Opts, maybe_ipv6(dummy, dummy, Opts))
        end
      }

    , { "tuple v4",
        fun() -> assert_v4({127, 0, 0, 1}) end
      }
    , { "tuple v6",
        fun() -> assert_v6({0, 0, 0, 0, 0, 0, 0, 1}) end
      }
    , { "ip str v4",
        fun() -> assert_v4("127.0.0.1") end
      }
    , { "ip str v6",
        fun() -> assert_v6("::1") end
      }
    , { "localhost v4",
         fun() -> with_listener(inet, fun(Port) -> assert_v4("localhost", Port) end) end
      }
    , { "localhost v6",
         fun() -> with_listener(inet6, fun(Port) -> assert_v6("localhost", Port) end) end
      }
    , { "localhost dual-stack",
         fun() ->
                 {V4Listener, Port} = listen([ipv4()]),
                 {V6Listener, Port} = listen(Port, [ipv6()]),
                 try
                     assert_v6("localhost", Port)
                 after
                     gen_tcp:close(V4Listener),
                     gen_tcp:close(V6Listener)
                 end
         end
      }

    ].

maybe_ipv6(Host, Port, Opts) when is_list(Opts) ->
    maybe_ipv6(Host, Port, #{transport_opts => Opts});
maybe_ipv6(Host, Port, Opts) when is_map(Opts) ->
    ehttpc:maybe_ipv6(Host, Port, Opts).

assert_v4(Host) -> assert_v4(Host, dummy).

assert_v4(Host, Port) ->
    ?assertMatch(#{transport_opts := [inet]}, maybe_ipv6(Host, Port, [])).

assert_v6(Host) -> assert_v6(Host, dummy).

assert_v6(Host, Port) ->
    ?assertMatch(#{transport_opts := [inet6]}, maybe_ipv6(Host, Port, [])).

with_listener(inet, Fun) ->
    with_listener([ipv4()], Fun);
with_listener(inet6, Fun) ->
    with_listener([ipv6()], Fun);
with_listener(Opts, Fun) ->
    case listen(Opts) of
        ignore ->
            ok;
        {Listener, Port} ->
            try
                Fun(Port)
            after
                gen_tcp:close(Listener)
            end
    end.

listen(Opts) -> listen(12345, Opts).

listen(Port, Opts) ->
    case gen_tcp:listen(Port, Opts) of
        {ok, Listener} -> {Listener, Port};
        {error, eaddrinuse} -> listen(Port + 1, Opts)
    end.

ipv4() -> {ip, {0, 0, 0, 0}}.

ipv6() -> {ip, {0, 0, 0, 0, 0, 0, 0, 1}}.
