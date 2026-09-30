-module(yammr_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ConfigPath = os:getenv("YAMMR_CONFIG_PATH", "/etc/yammr/config.toml"),
    yammr_sup:start_link(ConfigPath),

    {ok, YammrPort} = yammr_config:get([server, port]),

    % Configure
    % Compile the routes into a opaque dispatch rules
    Dispatch = cowboy_router:compile([{'_', proxy_config() ++ oidc_config() ++ yammr_ui:routes()}]),
    {ok, _Pid} = cowboy:start_clear(yammr_proxy, [{port, YammrPort}], #{
        env => #{dispatch => Dispatch}
    }).

stop(_State) ->
    ok.

%% internal functions
oidc_config() ->
    {ok, ClientId} = yammr_config:get([oidc, client_id]),
    {ok, ClientSecret} = yammr_config:get([oidc, client_secret]),
    {ok, ClientRedirectURI} = yammr_config:get([oidc, client_redirect_uri]),
    AuthOpts = #{
        client_id => ClientId,
        client_secret => ClientSecret,
        client_redirect_uri => ClientRedirectURI
    },
    [
        {"/yammr/auth/login", yammr_auth_handler, AuthOpts#{action => login}},
        {"/yammr/auth/callback", yammr_auth_handler, AuthOpts#{action => callback}},
        {"/yammr/auth/logout", yammr_auth_handler, AuthOpts#{action => logout}}
    ].

proxy_config() ->
    {ok, UpHost} = yammr_config:get([upstream, host]),
    {ok, UpPort} = yammr_config:get([upstream, port]),
    {ok, UpToken} = yammr_config:get([upstream, api_token]),
    [
        {"/v1/[...]", yammr_oai_proxy, #{
            up_host => binary_to_list(UpHost),
            up_port => UpPort,
            up_token => binary_to_list(UpToken)
        }}
    ].
