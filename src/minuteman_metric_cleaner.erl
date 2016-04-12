%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%% We implicitly create metrics for every backend that minuteman sees
%%% unfortunately, this can result in a memory leak which is quite bad.
%%% In order to work around this, we want to eventually clean out the VIPs
%%% @end
%%% Created : 11. Apr 2016 5:58 PM
%%%-------------------------------------------------------------------
-module(minuteman_metric_cleaner).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-compile(inline_list_funcs).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(backend_entry, {backend_ip_port, last_seen}).
-type backend_entry() :: #backend_entry{}.

-record(state, {backends = []}).
%% Retain metrics for no longer than this many seconds
-define(RETAIN_MAX_SECS, 3600).

%% Retain metrics for at least this many seconds
-define(RETAIN_MIN_SECS, 300).

%% If there are metrics older than RETAIN_MIN_SECS, but younger than RETAIN_MAX_SECS,
%% ensure the total number of metrics doesn't exceed RETAIN_MAX_COUNT
-define(RETAIN_MAX_COUNT, 1000).

%% Purge this often
-define(PURGE_INTERVAL_MSECS, 71 * 1000).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    clear_entries(),
    minuteman_vip_events:add_sup_handler(fun(Vips) -> gen_server:cast(?SERVER, {push_vips, Vips}) end),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    timer:send_after(?PURGE_INTERVAL_MSECS, purge),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({push_vips, Vips}, State) ->
    State1 = handle_push_vips(Vips, State),
    {noreply, State1};
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(purge, State) ->
    State1 = handle_purge(State),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_push_vips(Vips, State = #state{backends = OldBackends}) ->
    Now = erlang:monotonic_time(seconds),
    BackendsIPPorts = lists:foldl(fun collect_backends/2, ordsets:new(), Vips),
    Backends = lists:map(fun(BE) -> #backend_entry{backend_ip_port = BE, last_seen = Now} end, BackendsIPPorts),
    SortedBackends = lists:keysort(#backend_entry.backend_ip_port, Backends),
    SortedOldBackends = lists:keysort(#backend_entry.backend_ip_port, OldBackends),
    NewBackends = lists:ukeymerge(#backend_entry.backend_ip_port, SortedBackends, SortedOldBackends),
    State#state{backends = NewBackends}.


collect_backends({_Vip, Backends}, Acc0) ->
    Backends1 = ordsets:from_list(Backends),
    ordsets:union(Acc0, Backends1).
handle_purge(State = #state{backends = Backends}) ->
    {OldBEs, Backends1} = purge(Backends),
    lists:foreach(fun delete_metrics/1, OldBEs),
    State#state{backends = Backends1}.

-spec(purge(Backends :: [backend_entry()]) -> {OldEntries :: [backend_entry()], RetainedEntries :: [backend_entry()]}).
purge(Backends) ->
    Now = erlang:monotonic_time(seconds),
    SortedBackends = lists:keysort(#backend_entry.last_seen, Backends),
    {_Now, BackendsToKeep, BackendsToDrop} = lists:foldl(fun purge_fold/2, {Now, [], []}, SortedBackends),
    {BackendsToDrop, BackendsToKeep}.

%% Backend too old
purge_fold(Backend = #backend_entry{last_seen = LS}, {Now, BackendsToKeep, BackendsToDrop})
    when LS < Now - ?RETAIN_MAX_SECS ->
    {Now, BackendsToKeep, [Backend|BackendsToDrop]};
purge_fold(Backend = #backend_entry{last_seen = LS}, {Now, BackendsToKeep, BackendsToDrop})
    when LS > Now - ?RETAIN_MIN_SECS ->
    {Now, [Backend|BackendsToKeep], BackendsToDrop};
purge_fold(Backend, {Now, BackendsToKeep, BackendsToDrop}) when length(BackendsToKeep) < ?RETAIN_MAX_COUNT ->
    {Now, [Backend|BackendsToKeep], BackendsToDrop};
purge_fold(Backend, {Now, BackendsToKeep, BackendsToDrop}) ->
    {Now, BackendsToKeep, [Backend|BackendsToDrop]}.

delete_metrics(_Backend = #backend_entry{backend_ip_port = BackendIPPort}) ->
    lager:debug("Deleting metric for backend: ~p", [BackendIPPort]),
    ToDelete = exometer:find_entries([backend, BackendIPPort]),
    NamesToDelete = [Name || {Name, _Type, _Status} <- ToDelete],
    lists:foreach(fun exometer:delete/1, NamesToDelete),
    lager:debug("Deleting metrics: ~p", [NamesToDelete]).

clear_entries() ->
    ToDelete = exometer:find_entries([backend]),
    NamesToDelete = [Name || {Name, _Type, _Status} <- ToDelete],
    lists:foreach(fun exometer:delete/1, NamesToDelete).


-ifdef(TEST).
shuffle_list(List) ->
    ShuffledList = lists:sort([{rand:uniform(), Item} || Item <- List]),
    [Item || {_, Item} <- ShuffledList].

nopurge_test() ->
    Now = erlang:monotonic_time(seconds),
    %% 1. Test that we don't accidentally purge metrics
    Backends = [#backend_entry{last_seen = Now, backend_ip_port = Idx} || Idx <- lists:seq(1, ?RETAIN_MAX_COUNT * 2)],
    SortedBackends = lists:sort(Backends),
    {[], RemainingBackends} = purge(Backends),
    true = lists:sort(RemainingBackends) == SortedBackends.

purge_too_old_test() ->
    Now = erlang:monotonic_time(seconds),
    KeepBackends = [#backend_entry{last_seen = Now, backend_ip_port = Idx} ||
        Idx <- lists:seq(1, ?RETAIN_MAX_COUNT * 2)],
    LastTimestamp = Now - ?RETAIN_MAX_SECS - 1,
    LoseBackends = [#backend_entry{last_seen = LastTimestamp, backend_ip_port = Idx} ||
        Idx <- lists:seq(1, ?RETAIN_MAX_COUNT * 2)],
    ShuffledBackends = shuffle_list(KeepBackends ++ LoseBackends),
    {LoseBackends1, KeepBackends1} = purge(ShuffledBackends),
    true = lists:sort(KeepBackends) == lists:sort(KeepBackends1),
    true = lists:sort(LoseBackends) == lists:sort(LoseBackends1).

purge_too_many_test() ->
    Now = erlang:monotonic_time(seconds),
    LastTimestamp = Now - ?RETAIN_MIN_SECS - 1,
    Backends = [#backend_entry{last_seen = LastTimestamp, backend_ip_port = Idx} ||
        Idx <- lists:seq(1, ?RETAIN_MAX_COUNT * 2)],
    {LoseBackends1, KeepBackends1} = purge(Backends),
    ?RETAIN_MAX_COUNT = length(KeepBackends1),
    true = length(LoseBackends1) == length(Backends) - ?RETAIN_MAX_COUNT.

-endif.


