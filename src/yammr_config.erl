-module(yammr_config).
-behaviour(gen_server).

% Yammr config server

%% API
-export([
		 start_link/0,
		 load/1,
		 get/1
		]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

load(ConfigPath) -> 
	gen_server:call(?MODULE, {load, ConfigPath}).

get(Data) -> 
	gen_server:call(?MODULE, {get, Data}).


% Callbacks

init([]) ->
    {ok, #{}}.

handle_call({load, ConfigFile}, _From, _Config0) ->
	{ok, Config1} = tomerl:read_file(ConfigFile),
	% TODO: Add validation via Jesse
    {reply, {ok, loaded}, Config1};
handle_call({get, Data}, _From, Config0) ->
	Result = tomerl:get(Data, Config0),
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
