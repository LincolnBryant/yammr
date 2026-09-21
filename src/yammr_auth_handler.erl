-module(yammr_auth_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, #{action := login} = Opts) -> login(Req, Opts);
init(Req, #{action := callback} = Opts) -> callback(Req, Opts).
%init(Req, #{action := logout} = Opts) -> logout(Req, Opts).

login(Req0, Opts) ->
    #{
        client_id := ClientID,
        client_secret := ClientSecret,
        client_redirect_uri := ClientRedirectUri
    } = Opts,

    State = yammr_util:rand_token(),
    Nonce = yammr_util:rand_token(),
    PkceVerifier = yammr_util:rand_token(),

	{ok, HandshakeId} = yammr_auth_ets:store(#{
        state => State,
        nonce => Nonce,
        pkce_verifier => PkceVerifier
    }),

    {ok, Url} = oidcc:create_redirect_url(yammr_oidc_provider, ClientID, ClientSecret, #{
        redirect_uri => ClientRedirectUri,
        scopes => [<<"openid">>, <<"profile">>, <<"email">>, <<"offline_access">>],
        state => State,
        nonce => Nonce,
        %% oidcc derives the S256 challenge
        pkce_verifier => PkceVerifier
    }),

    Req = cowboy_req:set_resp_cookie(<<"yammr_auth">>, HandshakeId, Req0, #{
        http_only => true,
        %% TODO: false for localhost dev, flag it in config
        secure => false,
        %% TODO: NOT strict - need to investigate
        same_site => lax,
        max_age => 600,
        path => <<"/yammr/auth">>
    }),
    {ok, cowboy_req:reply(302, #{~"location" => iolist_to_binary(Url)}, Req), Opts}.

callback(Req0, Opts) ->
    #{
        client_id := ClientID,
        client_secret := ClientSecret,
        client_redirect_uri := ClientRedirectUri
    } = Opts,
	HandshakeId = 
		case lists:keyfind(<<"yammr_auth">>, 1, cowboy_req:parse_cookies(Req0)) of
			{_, V} -> V;
			false -> undefined
		end,
    maybe
        % Grab the state from the ETS store
        {ok, Map} ?= yammr_auth_ets:take(HandshakeId),
        #{
            state := State,
            nonce := Nonce,
            pkce_verifier := PkceVerifier
        } = Map,
        % The state token from the client should match exactly
        QueryStringMap = maps:from_list(cowboy_req:parse_qs(Req0)),
        #{<<"state">> := State, <<"code">> := Code} ?= QueryStringMap,
        {ok, Token} ?=
            oidcc:retrieve_token(Code, yammr_oidc_provider, ClientID, ClientSecret, #{
                redirect_uri => ClientRedirectUri,
                nonce => Nonce,
                pkce_verifier => PkceVerifier
            }),
        % TODO: Exchange complete, should be able to pull out the refresh token
        % and access token and do something with them now. use this for minting the access token
        Claims = yammr_oidcc:id_claims(Token),
        {ok,
            cowboy_req:reply(
                200,
                #{<<"content-type">> => <<"application/json">>},
                json:encode(#{
                    message => success,
                    email => maps:get(<<"email">>, Claims, <<"?">>)
                }),
                Req0
            ), Opts}
    else
        {error, does_not_exist} ->
			logger:notice("Stashed state retrieval failed: requested entry does not exist in ETS"),
            {ok, reply_bad_request("No handshake saved server-side", Req0), Opts};
        {error, OtherError} ->
            logger:notice("Token exchange failed: ~p", [OtherError]),
            {ok, reply_bad_request("Token exchange failed", Req0), Opts};
        #{<<"error">> := Err} ->
            logger:notice("Bad reply from Okta: ~p", [Err]),
            {ok, reply_bad_request("Bad reply from Okta", Req0), Opts};
        #{<<"state">> := BadState} ->
            logger:notice("State did not match: ~p)", [BadState]),
            {ok, reply_bad_request("Expected state did not match", Req0), Opts};
		Err -> 
			logger:notice("Missing some other state/code: ~p", [Err]),
            {ok, reply_bad_request("Missing some other state", Req0), Opts}
    end.

reply_bad_request(Reason, Req0) ->
    Body = json:encode(#{error => #{message => iolist_to_binary(Reason), type => <<"bad_request">>}}),
    cowboy_req:reply(
        400,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req0
    ).
