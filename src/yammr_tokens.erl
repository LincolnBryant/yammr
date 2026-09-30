-module(yammr_tokens).
-behaviour(gen_server).

-export([start_link/0, mint/1, lookup/1, revoke/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-type user() :: binary().
%% What the dashboard may show after minting: the fixed prefix, and when.
-type token_info() :: #{prefix := binary(), created := integer()}.

-define(PREFIX, <<"yk_">>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Mint a fresh token for the user, replacing any existing one.
%% Returns the plaintext secret; it is not retrievable afterwards.
-spec mint(user()) -> {ok, Secret :: binary(), token_info()}.
mint(User) ->
    gen_server:call(?MODULE, {mint, User}).

-spec lookup(user()) -> {ok, token_info()} | none.
lookup(User) ->
    gen_server:call(?MODULE, {lookup, User}).

-spec revoke(user()) -> ok.
revoke(User) ->
    gen_server:call(?MODULE, {revoke, User}).

init([]) ->
    {ok, #{}}.

handle_call({mint, User}, _From, Tokens) ->
    Secret = <<?PREFIX/binary, (yammr_util:rand_token())/binary>>,
    Info = #{
        reveal => ?PREFIX,
        created => erlang:system_time(second)
    },
    Stored = Info#{hash => crypto:hash(sha256, Secret)},
    {reply, {ok, Secret, Info}, Tokens#{User => Stored}};
handle_call({lookup, User}, _From, Tokens) ->
    Reply =
        case Tokens of
            #{User := Stored} -> {ok, maps:without([hash], Stored)};
            _ -> none
        end,
    {reply, Reply, Tokens};
handle_call({revoke, User}, _From, Tokens) ->
    {reply, ok, maps:remove(User, Tokens)}.

handle_cast(_Msg, Tokens) -> {noreply, Tokens}.
