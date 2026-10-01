-module(yammr_util).

-export([rand_token/0]).
-export([reply_json/3]).

% Create a strong random token
rand_token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

reply_json(bad_gateway, Msg, Req) ->
    Headers = #{<<"content-type">> => <<"application/json">>},
    Body = json:encode(Msg),
    cowboy_req:reply(502, Headers, Body, Req);
reply_json(timeout, Msg, Req) ->
    Headers = #{<<"content-type">> => <<"application/json">>},
    Body = json:encode(Msg),
    cowboy_req:reply(504, Headers, Body, Req);
reply_json(unauthorized, Msg, Req) ->
    Headers = #{<<"content-type">> => <<"application/json">>},
    Body = json:encode(Msg),
    cowboy_req:reply(401, Headers, Body, Req).
