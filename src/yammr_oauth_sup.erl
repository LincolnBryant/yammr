%%%-------------------------------------------------------------------
%% @doc yammr top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(yammr_oauth_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
	{ok, IssuerBin} = yammr_config:get([oidc, issuer]),
    ChildSpecs = [
        #{
            id => oidcc_provider_configuration_worker,
            start =>
                {oidcc_provider_configuration_worker, start_link, [
                    #{
                        issuer => IssuerBin,
                        name => {local, yammr_oidc_provider}
                    }
                ]},
            shutdown => brutal_kill
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
