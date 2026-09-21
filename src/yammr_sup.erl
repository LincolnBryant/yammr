%%%-------------------------------------------------------------------
%% @doc yammr top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(yammr_sup).

-behaviour(supervisor).

-export([start_link/1]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link(ClientIssuer) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [ClientIssuer]).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([ClientIssuer]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [
        #{
            id => oidcc_provider_configuration_worker,
            start =>
                {oidcc_provider_configuration_worker, start_link, [
                    #{
                        issuer => ClientIssuer,
                        name => {local, yammr_oidc_provider}
                    }
                ]},
            shutdown => brutal_kill
        },
        #{
            id => yammr_auth_ets,
            start => {yammr_auth_ets, start_link, []}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
