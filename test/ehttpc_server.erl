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
    loop(fetch_header, Socket, Opts, <<>>).


loop(check_header_and_continue_fetch_if_not_ready, Socket, Opts, Buffer) ->
    case string:find(Buffer, <<"\r\n\r\n">>) of
        nomatch -> 
            loop(fetch_header, Socket, Opts, Buffer);
        _Match -> 
            loop(parse_header, Socket, Opts, Buffer)
    end;
loop(fetch_header, Socket, Opts, Buffer) ->
    %% Read data until we get a double new line
    %% This means that we have received the header and can go on to parse the header
    case gen_tcp:recv(Socket, 0) of
        {ok, Data0} ->
            Data1 = <<Buffer/binary, Data0/binary>>,
            loop(check_header_and_continue_fetch_if_not_ready, Socket, Opts, Data1);
        {error, _Reason} ->
            ok
    end;
loop(parse_header, Socket, Opts, Buffer) ->
    [Header | Rest] =
         binary:split(Buffer, <<"\r\n\r\n">>, []),
    NewBuffer =
        case re:run(Header, <<"transfer-encoding:.*chunked">>, [caseless]) of
            nomatch ->
                BytesLeftToRead = get_body_length(Header),
                read_normal_body(Socket, iolist_to_binary(Rest), BytesLeftToRead);
            _ ->
                read_chunked_body(Socket, iolist_to_binary(Rest))
        end,
    IsHead = 
        case re:run(Header, <<"^HEAD ">>, [caseless]) of
            nomatch ->
                false;
            _ ->
                true
        end,
    loop_send_response(Socket, Opts, NewBuffer, IsHead).

loop_send_response(Socket, Opts, Buffer, IsHead) ->
    Response = make_response(Opts, IsHead),
    Delay0 = maps:get(delay, Opts, 0),
    Ms =
        case Delay0 of
            {rand, D} -> rand:uniform(D);
            _ -> Delay0
        end,
    Ms > 0 andalso delay(Socket, Ms),
    case socket_send(Socket, Response, Opts) of
        ok ->
            case maps:get(oneoff, Opts, false) of
                true ->
                    gen_tcp:shutdown(Socket, write),
                    exit(normal);
                false ->
                    ok
            end,
            loop(check_header_and_continue_fetch_if_not_ready, Socket, Opts, Buffer);
        {error, _Reason} ->
            ok
    end.

get_body_length(Header) ->
    case re:run(Header, <<"content-length:.*(\\d+)">>, [caseless]) of
        nomatch -> 0;
        {match,[_,{Pos,Len}|_]} ->
            binary_to_integer(iolist_to_binary(string:substr(binary_to_list(Header), Pos+1,Len)))
    end.


read_normal_body(_Socket, Buffer, BytesLeftToRead)  when size(Buffer) >= BytesLeftToRead ->
    <<_:BytesLeftToRead/binary,Rest/binary>> = Buffer,
    Rest;
read_normal_body(Socket, Buffer, BytesLeftToRead) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            read_normal_body(Socket, NewBuffer, BytesLeftToRead)
    end.

read_chunked_body(Socket, Buffer) ->
    %% check if buffer contains end chunk (very hacky)
    LastChunk = <<"0\r\n\r\n">>,
    case string:find(Buffer, LastChunk) of
        nomatch ->
            %% Get some more data and try again
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} ->
                    NewBuffer = <<Buffer/binary, Data/binary>>,
                    read_chunked_body(Socket, NewBuffer)
            end;
        RemainingPlusLastChunk -> 
            iolist_to_binary(string:slice(RemainingPlusLastChunk, string:length(LastChunk)))
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

socket_send(
    Socket,
        #{
            headers := Headers,
            body_chunks := BodyChunks
        },
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
                    ok;
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

make_response(Opts, IsHead) ->
    Headers0 =
        [
            "HTTP/1.1 200 OK\r\n",
            "Server: ehttpc_test_server\r\n",
            "Date: Tue, 07 Mar 2022 01:10:09 GMT\r\n"
        ],
    {MoreHeaders, BodyChunks} =
        case Opts of
            #{chunked := _} ->
                Chunks =
                    case IsHead of
                        true -> [];
                        false -> make_chunks(Opts)
                    end,
                {["Transfer-Encoding: chunked", "\r\n", "\r\n"], Chunks};
            _ ->
                Body = 
                    case IsHead of
                        true -> [];
                        false -> [iolist_to_binary(lists:duplicate(100, 0))]
                    end,
                Len = integer_to_list(iolist_size(Body)),
                {["Content-Length: ", Len, "\r\n", "\r\n"], Body}
        end,
    Headers = Headers0 ++ MoreHeaders,
    Resp = #{
        headers => Headers,
        body_chunks => BodyChunks
    },
    Resp.

make_chunks(#{chunked := #{chunk_size := Size, chunks := Count}}) ->
    %% we use the counts to generat bytes, (to verify the final number of chunks received)
    Count > 255 andalso error({bad_chunk_count, Count}),
    RawL = [iolist_to_binary(lists:duplicate(Size, I)) || I <- lists:seq(1, Count)],
    [cow_http_te:chunk(I) || I <- RawL] ++ [cow_http_te:last_chunk()].
