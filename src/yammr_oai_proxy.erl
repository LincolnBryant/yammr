-module(yammr_oai_proxy).
-behaviour(cowboy_loop).

-export([
    init/2,
    info/3,
    terminate/3
]).

-define(SSE_TIMEOUT, 30_000).
-define(BODY_TIMEOUT, 30_000).

allowed(~"GET", ~"/v1/models") -> true;
allowed(~"POST", ~"/v1/chat/completions") -> true;
allowed(~"POST", ~"/v1/completions") -> true;
allowed(~"POST", ~"/v1/embeddings") -> true;
allowed(_, _) -> false.

init(Req0, State) ->
    case allowed(cowboy_req:method(Req0), cowboy_req:path(Req0)) of
        true ->
            proxy(Req0, State);
        false ->
            Req = cowboy_req:reply(
                403,
                #{~"content-type" => ~"application/json"},
                ~"{\"error\":{\"message\":\"forbidden\",\"type\":\"invalid_request_error\"}}",
                Req0
            ),
            {ok, Req, State}
    end.

proxy(Req0, #{uphost := UpHost, upport := UpPort} = State) ->
    {ok, ConnPid} = gun:open(UpHost, UpPort, #{
        protocols => [http],
        http_opts => #{content_handlers => [gun_data_h]},
        retry => 0
    }),
    % TODO: Send a 502 if await_up fails
    {ok, _Proto} = gun:await_up(ConnPid),
    MRef = monitor(process, ConnPid),

    {StreamRef, Req1} = relay(ConnPid, Req0),

    % TODO: Send a 502 if await_up fails
    {response, IsFin, Status, Headers} = gun:await(ConnPid, StreamRef, MRef),
    case is_sse(Headers) of
        true ->
            Req2 = cowboy_req:stream_reply(
                Status,
                #{
                    ~"content-type" => ~"text/event-stream",
                    ~"cache-control" => ~"no-cache"
                },
                Req1
            ),
            {cowboy_loop, Req2, State#{
                gun_conn => ConnPid,
                gun_mref => MRef,
                gun_stream_ref => StreamRef,
                idle_timer => erlang:send_after(?SSE_TIMEOUT, self(), sse_timeout)
            }};
        false ->
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
            {ok, Req2, State}
    end.

relay(ConnPid, Req0) ->
    Headers = cowboy_req:headers(Req0),
    Path = cowboy_req:path(Req0),
    Method = cowboy_req:method(Req0),
    case Method of
        ~"GET" ->
            StreamRef = gun:get(ConnPid, Path, Headers),
            {StreamRef, Req0};
        ~"POST" ->
            % Might have an issue above 8MB
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            StreamRef = gun:post(ConnPid, Path, Headers, Body),
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

sanitize_response_headers(HeaderMap) ->
    maps:without(
        [
            ~"connection",
            ~"transfer-encoding",
            ~"keep-alive",
            ~"content-length"
        ],
        HeaderMap
    ).

arm_timer(State) ->
    TRef1 = erlang:send_after(?SSE_TIMEOUT, self(), sse_timeout),
    State#{idle_timer => TRef1}.

disarm_timer(#{idle_timer := TRef} = State) ->
    erlang:cancel_timer(TRef),
    State.
