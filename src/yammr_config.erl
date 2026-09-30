-module(yammr_config).
-behaviour(gen_server).

% Yammr config server

%% API
-export([
    start_link/1,
    reload/1,
    put/1,
    get/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

start_link(ConfigPath) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ConfigPath], []).

reload(ConfigPath) ->
    gen_server:call(?MODULE, {reload, ConfigPath}).

put(Data) ->
    gen_server:call(?MODULE, {put, Data}).

get(Data) ->
    gen_server:call(?MODULE, {get, Data}).

% Callbacks

init([ConfigPath]) ->
    Config = load_and_parse(ConfigPath),
    {ok, Config}.

handle_call({reload, ConfigPath}, _From, _Config0) ->
    Config = load_and_parse(ConfigPath),
    % TODO: Examine any state changes and restart things as needed.
    {reply, {ok, loaded}, Config};
handle_call({put, Data}, _From, Config0) ->
    Config1 = maps:merge(Config0, Data),
    {ok, Config2} = validate(Config1),
    {reply, {ok, loaded}, Config2};
handle_call({get, Data}, _From, Config0) ->
    Result = tomerl:get(Config0, Data),
    {reply, Result, Config0};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
load_and_parse(ConfigPath) ->
    {ok, Config1} = tomerl:read_file(ConfigPath),
    {ok, Config2} = validate(Config1),
    % TODO: The validation bits!
    Config2.

validate(Config) ->
    % TODO: Jesse stuff
    {ok, Config}.
