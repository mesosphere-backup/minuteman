%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 19. Dec 2015 3:12 AM
%%%-------------------------------------------------------------------
-module(minuteman_lb).
-author("Tyler Neely").

-behaviour(gen_server).

-dialyzer([{nowarn_function, [notify_metrics/2]}]).

%% API
-export([start_link/0,
  decr_pending/2,
  incr_pending/1,
  pick_backend/1,
  now/0,
  is_open/1,
  get_backend/1,
  cost/1
  ]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).


-include("minuteman.hrl").

-ifdef(TEST).
-include_lib("stdlib/include/qlc.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {}).
-record(reachability_cache, {
  cache = orddict:new() :: orddict:orddict(inet:ip4_address(), boolean()),
  tree = false :: false | lashup_gm_route:tree()
}).
-type reachability_cache() :: #reachability_cache{}.

%% How many lookups we do to populate the backends list in Minuteman
-define(LOOKUP_LIMIT, 20).

%% The threshold of backends before we use the probabilistic algorithm
-define(BACKEND_LIMIT, 10).


%%%===================================================================
%%% API
%%%===================================================================
incr_pending({IP, Port}) ->
  gen_server:cast(?SERVER, {incr_pending, {IP, Port}}).

decr_pending({IP, Port}, Success) ->
  gen_server:cast(?SERVER, {decr_pending, {IP, Port}, Success}).

get_backend({IP, Port}) ->
  get_backend_or_default({IP, Port}).

%%--------------------------------------------------------------------
%% @doc
%% Uses the power of two choices algorithm as described in:
%% Michael Mitzenmacher. 2001. The Power of Two Choices in Randomized
%% Load Balancing. IEEE Trans. Parallel Distrib. Syst. 12,
%% 10 (October 2001), 1094-1104.
%% @end
%%--------------------------------------------------------------------
-spec(pick_backend(list(ip_port())) -> {ok, #backend{}} | {error, atom()}).
pick_backend([]) ->
  {error, no_backends_available};

pick_backend(BackendAddrs) when length(BackendAddrs) > ?BACKEND_LIMIT ->
  minuteman_metrics:update([probabilistic_backend_picker], 1, spiral),
  Now = erlang:monotonic_time(),
  ReachabilityCache = reachability_cache(),
  Choice = probabilistic_backend_chooser(Now, ReachabilityCache, BackendAddrs, [], [], []),
  {ok, Choice};

pick_backend(BackendAddrs) ->
  minuteman_metrics:update([simple_backend_picker], 1, spiral),
  %% Pull backends out of ets.
  Now = erlang:monotonic_time(),
  Backends = [get_backend_or_default(Backend) || Backend <- BackendAddrs],

  {Up, Down} = lists:partition(fun (Backend) ->
                                   is_open(Now, Backend)
                               end, Backends),

  % If there are no backends up, may as well try one that's down.
  Choices = case Up of
              [] ->
                Down;
              _ ->
                Up
            end,
  Tree = tree(),
  {ReachableTrue, ReachableFalse} = lists:partition(
    fun(Backend) ->
      {IP, _Port} = Backend#backend.ip_port,
      is_reachable_real(IP, Tree)
    end,
    Choices),

  % If there's only one choice, use it.  Otherwise, try to get two
  % different random selections and pick the one with the better
  % cost.
  case Choices of
    [Choice] ->
      {ok, Choice};
    _ ->
      %% We know there must be at least two backends
      {Backend1, ReachableTrue1, ReachableFalse1} =
        choose_from_backends(ReachableTrue, ReachableFalse),
      {Backend2, _, _} =
        choose_from_backends(ReachableTrue1, ReachableFalse1),
      Choice = choose_backend_by_cost(Backend1, Backend2),
      {ok, Choice}
  end.


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
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
-spec(init(term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  process_flag(min_heap_size, 2000000),
  backend_connections = ets:new(backend_connections,
                                [set, {keypos, #backend.ip_port}, named_table, {read_concurrency, true}]),
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
handle_call(clear, _From, State) ->
  ets:delete_all_objects(backend_connections),
  {reply, ok, State};
handle_call({get_backend, {IP, Port}}, _From, State) ->
  {reply, get_backend_or_default({IP, Port}), State};
handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
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
handle_cast({decr_pending, {IP, Port}, Success}, State) ->
  notify_metrics(Success, {IP, Port}),
  Backend = get_backend_or_default({IP, Port}),
  Pending = Backend#backend.pending,
  %% TODO(tyler) make sure we aren't overreporting decr's, and then get rid of this max
  NewPending = max(0, Pending - 1),
  Backend2 = Backend#backend{pending = NewPending},
  Backend3 = track_success(Success, Backend2),
  true = ets:insert(backend_connections, Backend3),
  {noreply, State};

handle_cast({incr_pending, {IP, Port}}, State) ->
  Backend = get_backend_or_default({IP, Port}),
  Pending = Backend#backend.pending,
  NewPending = Pending + 1,
  Backend2 = Backend#backend{pending = NewPending},
  true = ets:insert(backend_connections, Backend2),
  {noreply, State};

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
terminate(_Reason, _State = #state{}) ->
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

%%--------------------------------------------------------------------
%% @doc
%% Returns the cost of this backend. This used to use an EWMA, but now
%% only returns the current number of pending requests.
%% @end
%%--------------------------------------------------------------------
-spec(cost(#backend{}) -> integer()).
cost(#backend{pending = Pending}) ->
  Pending.

%%--------------------------------------------------------------------
%% @doc
%% Determines if this backend is suitable for receiving traffic, based
%% on whether the failure threshold has been crossed.
%% @end
%%--------------------------------------------------------------------
-spec(is_open(Now :: integer(), _Backend :: #backend{}) -> boolean()).
is_open(_Now, #backend{consecutive_failures = Failures,
                       max_failure_threshold = Threshold}) when Failures < Threshold ->
  true;
is_open(Now, #backend{last_failure_time = Last,
                      failure_backoff = Backoff}) ->
  (Now - Last) > Backoff.

-spec(is_open(Backend :: #backend{}) -> boolean()).
is_open(Backend) ->
  Now = erlang:monotonic_time(),
  is_open(Now, Backend).


%%--------------------------------------------------------------------
%% @doc
%% Records failure and success statistics for a backend.
%% @end
%%--------------------------------------------------------------------
-spec(track_success(boolean(), B :: #backend{}) -> #backend{}).
track_success(true, Backend = #backend{total_successes = TotalSuccesses}) ->
  Backend#backend{total_successes = TotalSuccesses + 1,
                  consecutive_failures = 0};
track_success(false, Backend = #backend{total_failures = TotalFailures,
                                        consecutive_failures = ConsecutiveFailures}) ->
  Now = erlang:monotonic_time(nano_seconds),
  Backend#backend{total_failures = TotalFailures + 1,
                  consecutive_failures = ConsecutiveFailures + 1,
                  last_failure_time = Now};
track_success(no_success_change, Backend) ->
  Backend.


-spec(choose_from_backends(ReachableBackends :: [#backend{}], NotReachableBackends :: [#backend{}]) ->
  {Backend :: #backend{}, ReachableBackends1 :: [#backend{}], NotReachableBackends1 :: [#backend{}]}).
choose_from_backends(B1, B2) when length(B1) > 0 ->
  {B1Prime, Backend} = pop_item_from_list(B1),
  {Backend, B1Prime, B2};
choose_from_backends(B1, B2) when length(B2) > 0 ->
  {B2Prime, Backend} = pop_item_from_list(B2),
  {Backend, B1, B2Prime}.

-spec(pop_item_from_list(List :: [term()]) -> {ListPrime :: [term()], Item :: term()}).
pop_item_from_list(List) ->
  Size = length(List),
  Idx = rand:uniform(Size),
  Item = lists:nth(Idx, List),
  {L1, [_|L2]} = lists:split(Idx-1, List),
  ListPrime = L1 ++ L2,
  {ListPrime, Item}.


-spec(probabilistic_backend_chooser(Now :: integer(),
  ReachabilityCache :: reachability_cache(),
  RemainingBackendAddrs :: backends(),
  ReachableAndOpenBackends :: backends(),
  OpenBackends :: backends(),
  OtherBackends :: backends()) ->
  backend()
).
probabilistic_backend_chooser(_Now, _ReachabilityCache, _RemainingBackendAddrs, ReachableAndOpenBackends,
  _OpenBackends, _OtherBackends) when length(ReachableAndOpenBackends) == 2 ->
  minuteman_metrics:update([reachable_open_backend], 1, spiral),
  [Backend1, Backend2] = ReachableAndOpenBackends,
  choose_backend_by_cost(Backend1, Backend2);

%% Never do more than 20 lookups
%% Or let this kick-in if we run out of remaining backends
probabilistic_backend_chooser(_Now, _ReachabilityCache, RemainingBackendAddrs, ReachableAndOpenBackends,
  OpenBackends, OtherBackends)
  when length(ReachableAndOpenBackends) + length(OpenBackends) + length(OtherBackends) > ?LOOKUP_LIMIT
  orelse RemainingBackendAddrs == [] ->
  make_backend_choice(ReachableAndOpenBackends, OpenBackends, OtherBackends);

probabilistic_backend_chooser(Now, ReachabilityCache, RemainingBackendAddrs, ReachableAndOpenBackends,
  OpenBackends, OtherBackends) when length(RemainingBackendAddrs) > 0 ->
  {RemainingBackendAddrs1, Item} = pop_item_from_list(RemainingBackendAddrs),
  Backend = get_backend_or_default(Item),
  {IP, _Port} = Backend#backend.ip_port,
  {ReachabilityCache1, Reachable} = is_reachable(ReachabilityCache, IP),
  IsOpen = is_open(Now, Backend),
  %% We have three lists of nodes:
  %% 1. Nodes that are Reachable + Open (EWMA)
  %% 2. Nodes that are open
  %% 3. Nodes that are neither open nor reachable
  %% Our decision making is to prefer 1 first, then 2, etc..
  %% Given this we have to make a decision of which list to put things in, and this is what that does

  %% There is one exception where a node is reachable, and not open,
  %% We put that in the third list. It means that likely a task is broken

  case {Reachable, IsOpen} of
    {true, true} ->
      ReachableAndOpenBackends1 = [Backend|ReachableAndOpenBackends],
      probabilistic_backend_chooser(Now, ReachabilityCache1,
        RemainingBackendAddrs1, ReachableAndOpenBackends1, OpenBackends, OtherBackends);
    {false, true} ->
      OpenBackends1 = [Backend|OpenBackends],
      probabilistic_backend_chooser(Now, ReachabilityCache1,
        RemainingBackendAddrs1, ReachableAndOpenBackends, OpenBackends1, OtherBackends);
    {true, false} ->
      OtherBackends1 = [Backend|OtherBackends],
      probabilistic_backend_chooser(Now, ReachabilityCache1,
        RemainingBackendAddrs1, ReachableAndOpenBackends, OpenBackends, OtherBackends1);
    {false, false} ->
      OtherBackends1 = [Backend|OtherBackends],
      probabilistic_backend_chooser(Now, ReachabilityCache1,
        RemainingBackendAddrs1, ReachableAndOpenBackends, OpenBackends, OtherBackends1)
  end.

%% Might as well be randomly sorted
%% The reason behind this is that we populate these lists
%% based on calling pop_item_from_list.
%% Since this function randomly selects backends and adds them to the list,
%% when it comes to this point, the ordering might as well be random

-spec(make_backend_choice(ReachableAndOpenBackends :: backends(),
  OpenBackends :: backends(),
  OtherBackends :: backends()) ->
  backend()
).

make_backend_choice([Backend], _OpenBackends, _OtherBackends) ->
  minuteman_metrics:update([reachable_open_backend], 1, spiral),
  Backend;
make_backend_choice(_ReachableAndOpenBackends, [OpenBackend1, OpenBackend2|_], _OtherBackends) ->
  minuteman_metrics:update([open_backend], 1, spiral),
  choose_backend_by_cost(OpenBackend1, OpenBackend2);
make_backend_choice(_ReachableAndOpenBackends, [OpenBackend], _OtherBackends) ->
  minuteman_metrics:update([open_backend], 1, spiral),
  OpenBackend;
make_backend_choice(_ReachableAndOpenBackends, _OpenBackends, [OtherBackend]) ->
  minuteman_metrics:update([other_backend], 1, spiral),
  OtherBackend;
make_backend_choice(_ReachableAndOpenBackends, _OpenBackends, [OtherBackend1, OtherBackend2|_]) ->
  minuteman_metrics:update([other_backend], 1, spiral),
  choose_backend_by_cost(OtherBackend1, OtherBackend2);
make_backend_choice(_, _, _) ->
  exit(bad_state).


-spec(choose_backend_by_cost(#backend{}, #backend{}) -> #backend{}).
choose_backend_by_cost(A, B) ->
  case cost(A) < cost(B) of
    true -> A;
    false -> B
  end.

-spec(reachability_cache() -> reachability_cache()).
reachability_cache() ->
  #reachability_cache{tree = tree()}.

-spec(tree() -> lashup_gm_route:tree() | false).
tree() ->
  try lashup_gm_route:get_tree(node()) of
    {tree, Tree} -> Tree;
    false -> false
  catch
    _ -> false
  end.


is_reachable(ReachabilityCache = #reachability_cache{cache = Cache, tree = Tree}, IP) ->
  case orddict:find(IP, Cache) of
    {ok, Value} ->
      {ReachabilityCache, Value};
    _ ->
      Reachable = is_reachable_real(IP, Tree),
      ReachabilityCache1 = ReachabilityCache#reachability_cache{cache = orddict:store(IP, Reachable, Cache)},
      {ReachabilityCache1, Reachable}
  end.

%% Don't crash if lashup is broken
-spec(is_reachable_real(inet:ip4_address(), lashup_gm_route:tree() | false) -> boolean()).
is_reachable_real(_IP, false) ->
  false;
is_reachable_real(IP, Tree) ->
  Nodenames = minuteman_lashup_index:nodenames(IP),
  lists:any(fun(Node) -> lashup_gm_route:distance(Node, Tree) =/= infinity end, Nodenames).

get_backend_or_default({IP, Port}) ->
  case ets:lookup(backend_connections, {IP, Port}) of
    [ExistingBackend] ->
      ExistingBackend;
    [] ->
      #backend{ip_port = {IP, Port}}
  end.

now() ->
  erlang:monotonic_time(nano_seconds).

notify_metrics(true, {IP, Port}) ->
  minuteman_metrics:update([backend, {IP, Port}, successes], 1, spiral);
notify_metrics(false, {IP, Port}) ->
  minuteman_metrics:update([backend, {IP, Port}, failures], 1, spiral);
notify_metrics(_, _Backend) ->
  ok.


-ifdef(TEST).


ip() ->
  ?LET({I1, I2, I3, I4},
       {integer(0, 255), integer(0, 255), integer(0, 255), integer(0, 255)},
       {I1, I2, I3, I4}).

ip_port() ->
  ?LET({IP, Port},
       {ip(), integer(0, 65535)},
       {IP, Port}).

boolean_or_no_success() ->
  ?LET(I, integer(0, 2), case I of
                           0 -> true;
                           1 -> false;
                           2 -> no_success_change
                         end).

command(S) ->
  Vips = sets:to_list(S#test_state.known_vips),
  VipsPresent = (Vips =/= []),
  oneof([{call, ?MODULE, decr_pending, [ip_port(), boolean_or_no_success()]},
         {call, ?MODULE, incr_pending, [ip_port()]}] ++
        [{call, ?MODULE, pick_backend, [list(oneof(Vips))]} || VipsPresent]).

state_test() ->
  TestTuple = {{1, 2, 3, 4}, 5000},
  {ok, State} = init([]),
  ?assertEqual([], ets:lookup(backend_connections, TestTuple)),
  {noreply, State} = handle_cast({incr_pending, TestTuple}, State),
  ?assertNotEqual([], ets:lookup(backend_connections, TestTuple)),
  Backend = get_backend_or_default(TestTuple),
  ?assertEqual(1, Backend#backend.pending),
  ets:delete(backend_connections).

-endif.
