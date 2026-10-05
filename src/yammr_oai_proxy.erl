-module(yammr_oai_proxy).
-behaviour(cowboy_loop).

-export([
    init/2,
    info/3,
    terminate/3
]).

-define(SSE_TIMEOUT, 30_000).
-define(BODY_TIMEOUT, 30_000).

allowed(<<"GET">>, <<"/v1/models">>) -> true;
allowed(<<"POST">>, <<"/v1/chat/completions">>) -> true;
allowed(<<"POST">>, <<"/v1/completions">>) -> true;
allowed(<<"POST">>, <<"/v1/embeddings">>) -> true;
allowed(_, _) -> false.

init(Req0, State) ->
    case allowed(cowboy_req:method(Req0), cowboy_req:path(Req0)) of
        true ->
            proxy(Req0, State);
        false ->
            Req = cowboy_req:reply(
                403,
                #{<<"content-type">> => <<"application/json">>},
                <<"{\"error\":{\"message\":\"forbidden\",\"type\":\"invalid_request_error\"}}">>,
                Req0
            ),
            {ok, Req, State}
    end.

proxy(Req0, #{up_host := UpHost, up_port := UpPort, up_token := UpToken} = State) ->
    {ok, ConnPid} = gun:open(UpHost, UpPort, #{
        protocols => [http],
        http_opts => #{content_handlers => [gun_data_h]},
        retry => 0
    }),
    % Replace any existing bearer token from the client with ours
    % TODO: Authenticate presented token
    maybe
        {ok, _Proto} ?= gun:await_up(ConnPid),
        MRef = monitor(process, ConnPid),
        % Check validity of the key
        {ok, _User} ?= valid_token(Req0),
        {StreamRef, Req1} = relay(UpToken, ConnPid, Req0),
        {response, IsFin, Status, Headers} ?= gun:await(ConnPid, StreamRef, MRef),
        case is_sse(Headers) of
            true ->
                reply_stream(Status, ConnPid, MRef, StreamRef, Req1, State);
            false ->
                reply_buffered(Headers, IsFin, Status, ConnPid, MRef, StreamRef, Req1, State)
        end
    else
        % Timeout
        {error, timeout} ->
            Message =
                #{
                    error =>
                        #{
                            message => <<"Timeout connecting to upstream">>,
                            type => <<"Connection Timeout">>
                        }
                },
            Req2 = yammr_util:reply_json(timeout, Message, Req0),
            {ok, Req2, State};
        {error, invalid_token} ->
            Message =
                #{
                    error =>
                        #{
                            message => <<"Invalid token">>,
                            type => <<"Unauthorized">>
                        }
                },
            Req2 = yammr_util:reply_json(unauthorized, Message, Req0),
            {ok, Req2, State};
        % Failed to bring the connection up
        {error, Reason} ->
            logger:notice("Connection refused: ~p", [Reason]),
            Message =
                #{
                    error =>
                        #{
                            message => <<"Connection refused at upstream">>,
                            type => <<"Bad Gateway">>
                        }
                },
            Req2 = yammr_util:reply_json(bad_gateway, Message, Req0),
            {ok, Req2, State}
    end.

relay(UpToken, ConnPid, Req0) ->
    TokenBin = list_to_binary(UpToken),
    Headers0 = cowboy_req:headers(Req0),
    logger:notice("Headers: ~p", [Headers0]),
    Headers1 = Headers0#{<<"authorization">> => <<"Bearer ", TokenBin/binary>>},
    Path = cowboy_req:path(Req0),
    Method = cowboy_req:method(Req0),
    case Method of
        <<"GET">> ->
            StreamRef = gun:get(ConnPid, Path, Headers1),
            {StreamRef, Req0};
        <<"POST">> ->
            % Might have an issue above 8MB
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            StreamRef = gun:post(ConnPid, Path, Headers1, Body),
            {StreamRef, Req1}
    end.

% send the data to the summarizer to count tokens
info({gun_data, _ConnPid, _MRef, IsFin, Msg}, Req, State) ->
    %logger:notice("Relaying SSE message: ~p", [Msg]),
    cowboy_req:stream_body(Msg, IsFin, Req),
    case IsFin of
        fin ->
            {stop, Req, State};
        nofin ->
            % Disarm the current idle timeout and rearm
            State1 = arm_timer(disarm_timer(State)),
            {ok, Req, State1}
    end;
info({gun_error, _ConnPid, _StreamRef, Reason}, Req, State) ->
    logger:warning("upstream error: ~p", [Reason]),
    {stop, Req, State};
info({'DOWN', _MRef, process, _ConnPid, Reason}, Req, State) ->
    logger:warning("upstream down: ~p", [Reason]),
    {stop, Req, State};
info(sse_timeout, Req, State) ->
    logger:warning("SSE timed out"),
    {stop, Req, State};
info(Msg, Req, State) ->
    logger:warning("yammr_oai_proxy: unexpected message: ~p", [Msg]),
    {ok, Req, State}.

terminate(_Reason, _Req, #{gun_conn := ConnPid}) ->
    gun:close(ConnPid);
terminate(_Reason, _Req, _State) ->
    ok.

is_sse(Headers) ->
    case lists:keyfind(~"content-type", 1, Headers) of
        {_, <<"text/event-stream", _/binary>>} -> true;
        _ -> false
    end.

reply_stream(Status, ConnPid, MRef, StreamRef, Req1, State) ->
    Req2 = cowboy_req:stream_reply(
        Status,
        #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>
        },
        Req1
    ),
    {cowboy_loop, Req2, State#{
        gun_conn => ConnPid,
        gun_mref => MRef,
        gun_stream_ref => StreamRef,
        idle_timer => erlang:send_after(?SSE_TIMEOUT, self(), sse_timeout)
    }}.

reply_buffered(Headers, IsFin, Status, ConnPid, MRef, StreamRef, Req1, State) ->
    Body =
        case IsFin of
            fin ->
                <<>>;
            nofin ->
                % TODO: Send a 502 if await_up fails
                {ok, B} = gun:await_body(ConnPid, StreamRef, ?BODY_TIMEOUT, MRef),
                B
        end,
    HeaderMap = maps:from_list(Headers),
    SanitizedHeaders = sanitize_response_headers(HeaderMap),
    Req2 = cowboy_req:reply(Status, SanitizedHeaders, Body, Req1),
    {ok, Req2, State}.

sanitize_response_headers(HeaderMap) ->
    maps:without(
        [
            <<"connection">>,
            <<"transfer-encoding">>,
            <<"keep-alive">>,
            <<"content-length">>
        ],
        HeaderMap
    ).

arm_timer(State) ->
    TRef1 = erlang:send_after(?SSE_TIMEOUT, self(), sse_timeout),
    State#{idle_timer => TRef1}.

disarm_timer(#{idle_timer := TRef} = State) ->
    erlang:cancel_timer(TRef),
    State.

valid_token(Req0) ->
    case cowboy_req:parse_header(<<"authorization">>, Req0, {error, invalid_token}) of
        % Guard to make eqWalizer happy..
        {bearer, Token} when is_binary(Token) ->
            yammr_tokens:verify(Token);
        _ ->
            {error, invalid_token}
    end.
