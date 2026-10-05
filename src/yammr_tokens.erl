-module(yammr_tokens).
-behaviour(gen_server).

%% API tokens generated from the dashboard, persisted in DETS and cached in ETS.
%%
%% All calls go through the gen_server (same pattern as yammr_auth_store).
%% When the proxy hot path needs it, the ETS reads can move out of the
%% mailbox by reading the public tables directly from the caller.
-export([start_link/0, generate/1, lookup/1, verify/1, revoke/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-type user() :: binary().
%% What the dashboard may show after generation: the fixed prefix, and when.
-type token_info() :: #{prefix := binary(), created := integer()}.

-define(PREFIX, <<"yk_">>).

%% DETS table name (separate from the file path, which comes from config).
-define(DETS_TAB, yammr_tokens_dets).
%% ETS caches, owned by this gen_server. Public so callers can read them
%% directly once we move off gen_server:call for the hot path.
-define(BY_USER, yammr_tokens_by_user).
-define(BY_HASH, yammr_tokens_by_hash).

-record(state, {
    dets :: dets:tab_name(),
    by_user :: ets:tab(),
    by_hash :: ets:tab()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Generate a fresh token for the user, replacing any existing one.
%% Returns the plaintext secret; it is not retrievable afterwards.
-spec generate(user()) -> {ok, Secret :: binary(), token_info()}.
generate(User) ->
    gen_server:call(?MODULE, {generate, User}).

%% Dashboard view: does this user have a token, and what is its prefix?
-spec lookup(user()) -> {ok, token_info()} | none.
lookup(User) ->
    gen_server:call(?MODULE, {lookup, User}).

%% Proxy hot path: who presented this bearer secret?
-spec verify(Secret :: binary()) -> {ok, user()} | {error, invalid_token}.
verify(Secret) ->
    gen_server:call(?MODULE, {verify, Secret}).

-spec revoke(user()) -> ok.
revoke(User) ->
    gen_server:call(?MODULE, {revoke, User}).

init([]) ->
    DbPath = db_path(),
    ok = filelib:ensure_dir(DbPath),
    {ok, Dets} = dets:open_file(?DETS_TAB, [
        {file, DbPath}, {type, set}, {repair, true}, {auto_save, 60_000}
    ]),
    _ = lock_down(DbPath),
    ByUser = ets:new(?BY_USER, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ByHash = ets:new(?BY_HASH, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ok = load_from_dets(Dets, ByUser, ByHash),
    {ok, #state{dets = Dets, by_user = ByUser, by_hash = ByHash}}.

handle_call(
    {generate, User}, _From, State = #state{dets = Dets, by_user = ByUser, by_hash = ByHash}
) when is_binary(User) ->
    Secret = <<?PREFIX/binary, (yammr_util:rand_token())/binary>>,
    Hash = crypto:hash(sha256, Secret),
    Created = erlang:system_time(second),
    Prefix = ?PREFIX,
    Info = #{prefix => Prefix, created => Created},
    %% Durable first, then visible: a crash between the two leaves a row
    %% that reappears on reload, never a live token that vanishes.
    ok = dets:insert(Dets, {User, Hash, Prefix, Created}),
    ok = dets:sync(Dets),
    case ets:lookup(ByUser, User) of
        [{User, OldHash, _, _}] when OldHash =/= Hash ->
            ets:delete(ByHash, OldHash);
        _ ->
            ok
    end,
    true = ets:insert(ByUser, {User, Hash, Prefix, Created}),
    true = ets:insert(ByHash, {Hash, User}),
    {reply, {ok, Secret, Info}, State};
handle_call({lookup, User}, _From, State = #state{by_user = ByUser}) ->
    Reply =
        case ets:lookup(ByUser, User) of
            [{User, _Hash, Prefix, Created}] ->
                {ok, #{prefix => Prefix, created => Created}};
            [] ->
                none
        end,
    {reply, Reply, State};
handle_call({verify, Secret}, _From, State = #state{by_hash = ByHash}) when is_binary(Secret) ->
    Reply =
        case ets:lookup(ByHash, crypto:hash(sha256, Secret)) of
            [{_, User}] -> {ok, User};
            [] -> {error, invalid_token}
        end,
    {reply, Reply, State};
handle_call({verify, _BadSecret}, _From, State) ->
    {reply, {error, invalid_token}, State};
handle_call({revoke, User}, _From, State = #state{dets = Dets, by_user = ByUser, by_hash = ByHash}) ->
    case ets:lookup(ByUser, User) of
        [{User, Hash, _, _}] ->
            ets:delete(ByHash, Hash);
        [] ->
            ok
    end,
    ets:delete(ByUser, User),
    ok = dets:delete(Dets, User),
    ok = dets:sync(Dets),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{dets = Dets}) ->
    try dets:close(Dets) of
        _ -> ok
    catch
        _:_ -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

%% yammr.toml.example uses [server] db_path; accept the older [service]
%% key as a fallback so existing configs keep working.
db_path() ->
    case yammr_config:get([server, db_path]) of
        {ok, Path} ->
            to_path(Path);
        {error, not_found} ->
            {ok, Path} = yammr_config:get([service, db_path]),
            to_path(Path)
    end.

to_path(Path) when is_binary(Path) -> binary_to_list(Path);
to_path(Path) when is_list(Path) -> Path.

load_from_dets(Dets, ByUser, ByHash) ->
    Load = fun
        ({User, Hash, Prefix, Created}, ok) when
            is_binary(User), is_binary(Hash), is_binary(Prefix), is_integer(Created)
        ->
            ets:insert(ByUser, {User, Hash, Prefix, Created}),
            ets:insert(ByHash, {Hash, User}),
            ok;
        (_BadRow, ok) ->
            logger:warning("yammr_tokens: skipping malformed DETS row"),
            ok
    end,
    ok = dets:foldl(Load, ok, Dets).

%% Hashes only, but still treat the file like a credential store.
lock_down(DbPath) ->
    case file:change_mode(DbPath, 8#600) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning("yammr_tokens: could not chmod ~s: ~p", [DbPath, Reason]),
            ok
    end.
