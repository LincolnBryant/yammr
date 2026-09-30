%% Browser sessions for the web UI. A session is a random id in an HttpOnly
%% cookie pointing at a small user map held in yammr_auth_store. Nothing here
%% touches the API bearer tokens used on /v1 (see yammr_tokens).
-module(yammr_session).

-export([start/2, current/1, clear/1]).
-export_type([user/0]).

-type user() :: #{email := binary(), name := binary()}.

-define(COOKIE, <<"yammr_session">>).
% TODO: Determine a good TTL for the cookie

% 8hr
-define(TTL_MS, 8 * 60 * 60 * 1000).

%% Start a session from verified ID-token claims and set the cookie.
-spec start(map(), cowboy_req:req()) -> cowboy_req:req().
start(Claims, Req) ->
    Email = maps:get(<<"email">>, Claims, <<"unknown">>),
    Name = maps:get(<<"name">>, Claims, Email),
    {ok, Id} = yammr_auth_store:put(#{email => Email, name => Name}, ?TTL_MS),
    cowboy_req:set_resp_cookie(?COOKIE, Id, Req, cookie_opts(Req, ?TTL_MS div 1000)).

%% The signed-in user for this request, if any.
-spec current(cowboy_req:req()) -> {ok, user()} | none.
current(Req) ->
    case yammr_auth_store:lookup(cookie(Req)) of
        {ok, User} -> {ok, User};
        {error, _} -> none
    end.

%% Forget the session server-side and expire the cookie.
-spec clear(cowboy_req:req()) -> cowboy_req:req().
clear(Req) ->
    ok = yammr_auth_store:delete(cookie(Req)),
    cowboy_req:set_resp_cookie(?COOKIE, <<>>, Req, cookie_opts(Req, 0)).

%% Internal

cookie(Req) ->
    case lists:keyfind(?COOKIE, 1, cowboy_req:parse_cookies(Req)) of
        {_, V} -> V;
        false -> undefined
    end.

%% `secure' follows the scheme of the connection the cookie is set over
%% (cowboy:start_clear -> http, cowboy:start_tls -> https). A Secure cookie
%% sent over plain http is dropped by the browser, so this must reflect the
%% real transport rather than configuration.
cookie_opts(Req, MaxAge) ->
    #{
        http_only => true,
        secure => cowboy_req:scheme(Req) =:= <<"https">>,
        same_site => lax,
        max_age => MaxAge,
        path => <<"/">>
    }.
