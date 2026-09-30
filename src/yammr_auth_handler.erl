-module(yammr_auth_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% Where the browser lands after sign-in / sign-out (see yammr_ui:routes/0).
-define(SIGNED_IN_PATH, <<"/dashboard">>).
-define(SIGNED_OUT_PATH, <<"/">>).
-define(SIGNIN_FAILED_PATH, <<"/?error=1">>).

init(Req, #{action := login} = Opts) -> login(Req, Opts);
init(Req, #{action := callback} = Opts) -> callback(Req, Opts);
init(Req, #{action := logout} = Opts) -> logout(Req, Opts).

login(Req0, Opts) ->
    #{
        client_id := ClientID,
        client_secret := ClientSecret,
        client_redirect_uri := ClientRedirectUri
    } = Opts,

    State = yammr_util:rand_token(),
    Nonce = yammr_util:rand_token(),
    PkceVerifier = yammr_util:rand_token(),

    {ok, HandshakeId} = yammr_auth_store:put(#{
        state => State,
        nonce => Nonce,
        pkce_verifier => PkceVerifier
    }),

    OidcOpts = #{
        redirect_uri => ClientRedirectUri,
        scopes => [<<"openid">>, <<"profile">>, <<"email">>, <<"offline_access">>],
        state => State,
        nonce => Nonce,
        %% oidcc derives the S256 challenge
        pkce_verifier => PkceVerifier
    },
    case oidcc:create_redirect_url(yammr_oidc_provider, ClientID, ClientSecret, OidcOpts) of
        {ok, Url} ->
            Req = cowboy_req:set_resp_cookie(<<"yammr_auth">>, HandshakeId, Req0, #{
                http_only => true,
                %% TODO: false for localhost dev, flag it in config
                secure => false,
                %% TODO: NOT strict - need to investigate
                same_site => lax,
                max_age => 600,
                path => <<"/yammr/auth">>
            }),
            {ok, cowboy_req:reply(302, #{~"location" => iolist_to_binary(Url)}, Req), Opts};
        {error, {http_error, 400, #{<<"error_description">> := Err}}} ->
            logger:notice("Sign-in to Okta failed: ~p", [Err]),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts}
    end.

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
        {ok, Map} ?= yammr_auth_store:take(HandshakeId),
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
        logger:info("Sign-in complete for ~s", [maps:get(<<"email">>, Claims, <<"?">>)]),
        Req1 = yammr_session:start(Claims, Req0),
        {ok, redirect(?SIGNED_IN_PATH, Req1), Opts}
    else
        {error, does_not_exist} ->
            logger:notice("Stashed state retrieval failed: requested entry does not exist in ETS"),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts};
        {error, OtherError} ->
            logger:notice("Token exchange failed: ~p", [OtherError]),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts};
        #{<<"error">> := Err} ->
            logger:notice("Bad reply from Okta: ~p", [Err]),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts};
        #{<<"state">> := BadState} ->
            logger:notice("State did not match: ~p)", [BadState]),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts};
        Err ->
            logger:notice("Missing some other state/code: ~p", [Err]),
            {ok, redirect(?SIGNIN_FAILED_PATH, Req0), Opts}
    end.

logout(Req0, Opts) ->
    Req1 = yammr_session:clear(Req0),
    {ok, redirect(?SIGNED_OUT_PATH, Req1), Opts}.

%% Browser flow: every auth endpoint ends in a redirect back into the UI.
redirect(Location, Req) ->
    cowboy_req:reply(302, #{<<"location">> => Location}, Req).
