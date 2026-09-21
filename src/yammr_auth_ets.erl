-module(yammr_auth_ets).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([store/1, take/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(TTL_MS, 600_000).
-define(SWEEP_MS, 60_000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec store(map()) -> {ok, map()}.
store(Map) ->
    gen_server:call(?MODULE, {store, Map}).

take(Id) ->
    gen_server:call(?MODULE, {take, Id}).

init([]) ->
    Table = ets:new(?MODULE, [public, set, {write_concurrency, true}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, Table}.

handle_call({store, Map}, _From, Table) ->
    Id = yammr_util:rand_token(),
    true = ets:insert(Table, {Id, Map, erlang:monotonic_time(millisecond)}),
    {reply, {ok, Id}, Table};
handle_call({take, Id}, _From, Table) ->
    Resp =
        case ets:take(Table, Id) of
            [{_, Data, T}] ->
                Age = erlang:monotonic_time(millisecond) - T,
                case Age < ?TTL_MS of
                    true -> {ok, Data};
                    false -> {error, expired}
                end;
            [] ->
                {error, does_not_exist}
        end,
    {reply, Resp, Table};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% Periodically delete entries
handle_info(sweep, Table) ->
    %logger:notice("Sweeping stale data"),
    Cutoff = erlang:monotonic_time(millisecond) - ?TTL_MS,
    ets:select_delete(Table, [{{'_', '_', '$1'}, [{'<', '$1', Cutoff}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, Table};
handle_info(_Info, Table) ->
    {noreply, Table}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
