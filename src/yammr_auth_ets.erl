-module(yammr_auth_ets).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([store/1, store/2, take/1, lookup/1, delete/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Default TTL: long enough to complete an OIDC round trip.
-define(TTL_MS, 600_000).
-define(SWEEP_MS, 60_000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec store(map()) -> {ok, binary()}.
store(Map) ->
    store(Map, ?TTL_MS).

-spec store(map(), pos_integer()) -> {ok, binary()}.
store(Map, TtlMs) ->
    gen_server:call(?MODULE, {store, Map, TtlMs}).

%% Read and remove (one-shot handshake state).
-spec take(binary() | undefined) -> {ok, map()} | {error, does_not_exist | expired}.
take(Id) ->
    gen_server:call(?MODULE, {take, Id}).

%% Read without removing (sessions).
-spec lookup(binary() | undefined) -> {ok, map()} | {error, does_not_exist | expired}.
lookup(Id) ->
    gen_server:call(?MODULE, {lookup, Id}).

-spec delete(binary() | undefined) -> ok.
delete(Id) ->
    gen_server:call(?MODULE, {delete, Id}).

init([]) ->
    Table = ets:new(?MODULE, [public, set, {write_concurrency, true}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, Table}.

handle_call({store, Map, TtlMs}, _From, Table) ->
    Id = yammr_util:rand_token(),
    Expiry = erlang:monotonic_time(millisecond) + TtlMs,
    true = ets:insert(Table, {Id, Map, Expiry}),
    {reply, {ok, Id}, Table};
handle_call({take, Id}, _From, Table) ->
    {reply, check_validity(ets:take(Table, Id)), Table};
handle_call({lookup, Id}, _From, Table) ->
    {reply, check_validity(ets:lookup(Table, Id)), Table};
handle_call({delete, Id}, _From, Table) ->
    true = ets:delete(Table, Id),
    {reply, ok, Table};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% Periodically delete expired entries
handle_info(sweep, Table) ->
    Now = erlang:monotonic_time(millisecond),
    ets:select_delete(Table, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, Table};
handle_info(_Info, Table) ->
    {noreply, Table}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
check_validity([{_, Data, Expiry}]) ->
    case erlang:monotonic_time(millisecond) < Expiry of
        true -> {ok, Data};
        false -> {error, expired}
    end;
check_validity([]) ->
    {error, does_not_exist}.
