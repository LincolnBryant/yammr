%%%-------------------------------------------------------------------
%% @doc yammr top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(yammr_sup).

-behaviour(supervisor).

-export([start_link/1]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link(ConfigPath) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [ConfigPath]).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([ConfigPath]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [
        #{
            id => yammr_auth_store,
            start => {yammr_auth_store, start_link, []}
        },
        #{
            id => yammr_config,
            start => {yammr_config, start_link, [ConfigPath]}
        },
        #{
            id => yammr_oauth_sup,
            start => {yammr_oauth_sup, start_link, []},
            type => supervisor
        },
        %% API tokens minted from the dashboard (DETS-backed, ETS-cached)
        #{
            id => yammr_tokens,
            start => {yammr_tokens, start_link, []}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
