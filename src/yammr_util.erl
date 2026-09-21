-module(yammr_util).

-export([rand_token/0]).

% Create a strong random token
rand_token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).
