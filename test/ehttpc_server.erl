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

%% @doc A dead simple HTTP server
-module(ehttpc_server).

-export([
    start_link/1,
    stop/1
]).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% public
start_link(#{port := Port, name := Name} = Opts) ->
    spawn_link(
        fun() ->
            register(Name, self()),
            {ok, LSocket} = listen(Port),
            Acceptor = spawn_link(fun() ->
                ?tp(?MODULE, #{pid => self(), state => accepting}),
                accept(LSocket, Opts)
            end),
            receive
                stop ->
                    unlink(Acceptor),
                    gen_tcp:close(LSocket),
                    exit(Acceptor, kill),
                    exit(normal)
            end
        end
    ).

stop(undefined) ->
    ok;
stop(Name) when is_atom(Name) -> stop(whereis(Name));
stop(Pid) ->
    Mref = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Mref, _, _, _} ->
            ok
    after 2000 ->
        exit(Pid, kill),
        ok
    end.

%% private
accept(LSocket, Opts) ->
    case gen_tcp:accept(LSocket) of
        {ok, Socket} ->
            spawn_link(fun() -> loop(Socket, Opts) end),
            accept(LSocket, Opts);
        {error, _Reason} ->
            ok
    end.

count_requests([<<>>], N) ->
    {N, <<>>};
count_requests([Buffer], N) ->
    {N, Buffer};
count_requests([_ | T], N) ->
    count_requests(T, N + 1).

listen(Port) ->
    Self = self(),
    spawn_link(fun() ->
        Options = [binary, {backlog, 4096}, {active, false}, {reuseaddr, true}],
        Self ! gen_tcp:listen(Port, Options),
        receive
            _ ->
                ok
        end
    end),
    receive
        {ok, LSocket} ->
            {ok, LSocket}
    end.

loop(Socket, Opts) ->
    loop(Socket, Opts, <<>>).

loop(Socket, Opts, Buffer) ->
    Delay0 = maps:get(delay, Opts, 0),
    case gen_tcp:recv(Socket, 0) of
        {ok, Data0} ->
            Data1 = <<Buffer/binary, Data0/binary>>,
            Data = drop_last_chunk(Data1),
            Split = binary:split(Data, <<"\r\n\r\n">>, [global]),
            {N, Buffer2} = count_requests(Split, 0),
            Responses = make_responses(N, Opts),
            Ms =
                case Delay0 of
                    {rand, D} -> rand:uniform(D);
                    _ -> Delay0
                end,
            Ms > 0 andalso delay(Socket, Ms),
            case socket_send(Socket, Responses, Opts) of
                ok ->
                    case maps:get(oneoff, Opts, false) of
                        true ->
                            gen_tcp:shutdown(Socket, write),
                            exit(normal);
                        false ->
                            ok
                    end,
                    loop(Socket, Opts, Buffer2);
                {error, _Reason} ->
                    ok
            end;
        {error, _Reason} ->
            ok
    end.

delay(Socket, Timeout) ->
    ?tp(?MODULE, #{pid => self(), delay => Timeout}),
    receive
        close_socket ->
            gen_tcp:shutdown(Socket, write),
            exit(normal)
    after Timeout ->
        ok
    end.

socket_send(_Socket, [], _Opts) ->
    ok;
socket_send(
    Socket,
    [
        #{
            headers := Headers,
            body_chunks := BodyChunks
        }
        | Rest
    ],
    Opts
) ->
    ChunkedDelay =
        case Opts of
            #{chunked := #{delay := Delay}} ->
                Delay;
            _ ->
                0
        end,
    FinDelay =
        case Opts of
            #{chunked := #{fin_delay := Fd}} ->
                Fd;
            _ ->
                0
        end,
    case gen_tcp:send(Socket, Headers) of
        ok ->
            case socket_send_body_chunks(Socket, BodyChunks, ChunkedDelay, FinDelay) of
                ok ->
                    socket_send(Socket, Rest, Opts);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

socket_send_body_chunks(_Socket, [], _, _) ->
    ok;
socket_send_body_chunks(Socket, [H | T], Delay, FinDelay) ->
    case gen_tcp:send(Socket, H) of
        ok ->
            %% maybe delya each chunk (when Delay > 0)
            timer:sleep(Delay),
            case T of
                [_] when FinDelay > 0 ->
                    %% delay the last chunk
                    timer:sleep(FinDelay);
                _ ->
                    ok
            end,
            socket_send_body_chunks(Socket, T, Delay, FinDelay);
        {error, Reason} ->
            {error, Reason}
    end.

make_responses(0, _Opts) ->
    [];
make_responses(N, Opts) ->
    Headers0 =
        [
            "HTTP/1.1 200 OK\r\n",
            "Server: ehttpc_test_server\r\n",
            "Date: Tue, 07 Mar 2022 01:10:09 GMT\r\n"
        ],
    {MoreHeaders, BodyChunks} =
        case Opts of
            #{chunked := _} ->
                {["Transfer-Encoding: chunked", "\r\n", "\r\n"], make_chunks(Opts)};
            _ ->
                Body = iolist_to_binary(lists:duplicate(100, 0)),
                Len = integer_to_list(iolist_size(Body)),
                {["Content-Length: ", Len, "\r\n", "\r\n"], [Body]}
        end,
    Headers = Headers0 ++ MoreHeaders,
    Resp = #{
        headers => Headers,
        body_chunks => BodyChunks
    },
    [Resp | make_responses(N - 1, Opts)].

make_chunks(#{chunked := #{chunk_size := Size, chunks := Count}}) ->
    %% we use the counts to generat bytes, (to verify the final number of chunks received)
    Count > 255 andalso error({bad_chunk_count, Count}),
    RawL = [iolist_to_binary(lists:duplicate(Size, I)) || I <- lists:seq(1, Count)],
    [cow_http_te:chunk(I) || I <- RawL] ++ [cow_http_te:last_chunk()].

drop_last_chunk(Data) ->
    case re:run(Data, <<"transfer-encoding:.*chunked">>, [caseless]) of
        nomatch ->
            Data;
        _ ->
            Size = byte_size(Data),
            LastChunk = cow_http_te:last_chunk(),
            LastChunkSize = byte_size(LastChunk),
            case Size >= LastChunkSize andalso LastChunk =:= binary:part(Data, {Size, -LastChunkSize}) of
                true ->
                    binary:part(Data, 0, Size - LastChunkSize);
                false ->
                    Data
            end
    end.
