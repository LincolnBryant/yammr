-module(yammr_oidcc).
%% Accessors for oidcc's record-based API
-include_lib("oidcc/include/oidcc_token.hrl").

-export([id_claims/1, refresh_token/1]).

%% ID-token claims of a successful exchange only.
-spec id_claims(oidcc_token:t()) -> oidcc_jwt_util:claims().
id_claims(#oidcc_token{id = #oidcc_token_id{claims = Claims}}) ->
    Claims.

-spec refresh_token(oidcc_token:t()) -> {ok, binary()} | none.
refresh_token(#oidcc_token{refresh = #oidcc_token_refresh{token = Token}}) ->
    {ok, Token};
refresh_token(#oidcc_token{refresh = none}) ->
    none.
