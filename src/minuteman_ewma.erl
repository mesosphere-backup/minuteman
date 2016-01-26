%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 19. Dec 2015 3:12 AM
%%%-------------------------------------------------------------------
-module(minuteman_ewma).
-author("Tyler Neely").

-behaviour(gen_server).

%% API
-export([start_link/0,
  observe/3,
  set_pending/1,
  pick_backend/1,
  now/0,
  get_ewma/1,
  is_open/1,
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
-export([initial_state/0,
  stop/0,
  command/1,
  precondition/2,
  postcondition/3,
  next_state/3
  ]).
-include_lib("stdlib/include/qlc.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {}).
%% How many lookups we do to populate the backends list in Minuteman
-define(LOOKUP_LIMIT, 20).

%% The threshold of backends before we use the probabilistic algorithm
-define(BACKEND_LIMIT, 10).


%%%===================================================================
%%% API
%%%===================================================================
observe(Measurement, {IP, Port}, Success) ->
  gen_server:cast(?SERVER, {observe, {Measurement, {IP, Port}, Success}}).

set_pending({IP, Port}) ->
  gen_server:cast(?SERVER, {set_pending, {IP, Port}}).

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
%% 100 millisecond timeout for picking a backend seems reasonable
%% 10 milliseconds resulted in too many false failures
pick_backend(Backends) ->
  pick_backend_internal(Backends).


%%--------------------------------------------------------------------
%% @doc
%%--------------------------------------------------------------------
get_ewma({IP, Port}) ->
  %% TODO(tyler) remove gen_server, hit ets directly and handle case
  %% where the table is queried before being created.
  gen_server:call(?SERVER, {get_ewma, {IP, Port}}).

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
  random:seed(erlang:phash2([node()]),
              erlang:monotonic_time(),
              erlang:unique_integer()),
  connection_ewma = ets:new(connection_ewma, [set, {keypos, #backend.ip_port}, named_table, {read_concurrency, true}]),
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
handle_call({pick_backend, Backends}, _From, State) ->
  {reply, pick_backend_internal(Backends), State};
handle_call(clear, _From, State) ->
  ets:delete_all_objects(connection_ewma),
  {reply, ok, State};
handle_call({get_ewma, {IP, Port}}, _From, State) ->
  {reply, get_ewma_or_default({IP, Port}), State};
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
handle_cast({observe, {Measurement, {IP, Port}, Success}}, State) ->
  lager:debug("Observing connection success: ~p with time of ~.6f ms", [Success, Measurement / 1.0e6]),
  Backend = get_ewma_or_default({IP, Port}),
  Ewma = Backend#backend.ewma,
  Clock = Backend#backend.clock,
  ObservedEwma = observe_internal(Measurement, Clock(), Ewma),
  NewEwma = decrement_pending(Success, ObservedEwma),

  Tracking = Backend#backend.tracking,
  NewTracking = track_success(Success, Tracking),

  NewBackend = Backend#backend{ewma = NewEwma,
    tracking = NewTracking},
  true = ets:insert(connection_ewma, NewBackend),
  {noreply, State};


handle_cast({set_pending, {IP, Port}}, State) ->
  Backend = get_ewma_or_default({IP, Port}),
  NewEwma = increment_pending(Backend#backend.ewma),
  NewBackend = Backend#backend{ewma = NewEwma},
  true = ets:insert(connection_ewma, NewBackend),
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
%% Records a new value in the exponentially weighted moving average.
%% This type of algorithm shows up all over the place in load balancer
%% code, and here we're porting Twitter's P2CBalancerPeakEwma which
%% factors time into our moving average.  This is nice because we
%% can bias decisions more with recent information, allowing us to
%% not have to assume a constant request rate to a particular service.
%% @end
%%--------------------------------------------------------------------
-spec(observe_internal(Val :: float(), Now :: float(), _Ewma :: #ewma{}) -> #ewma{}).
observe_internal(Val, Now, Ewma = #ewma{cost = Cost,
                               stamp = Stamp,
                               decay = Decay}) ->
  TimeDelta = max(Now - Stamp, 0),
  Weight = math:exp(-TimeDelta / Decay),
  NewCost = case Val > Cost of
              true -> Val;
              false -> (Cost * Weight) + (Val * (1.0-Weight))
            end,
  Ewma#ewma{stamp = Now, cost = NewCost}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the cost of this according to the EWMA algorithm.
%% @end
%%--------------------------------------------------------------------
-spec(cost(#backend{}) -> float()).
cost(#backend{ip_port = IPPort, clock = Clock, ewma = Ewma}) ->
  % We observe 0 here to slide the exponential window forward by the
  % amount of time that has passed since the last measurement.
  Now = Clock(),
  #ewma{cost = Cost, pending = Pending, penalty = Penalty} = observe_internal(0.0, Now, Ewma),

  %% asynchronously persist a zero value, helping smooth things out over time
  observe(0.0, IPPort, no_success_change),

  case {float(Cost), float(Penalty)} of
    {0.0, 0.0} ->
      Cost * (Pending + 1);
    {0.0, _} ->
      Penalty + Pending;
    _ ->
      Cost * (Pending + 1)
  end.

%%--------------------------------------------------------------------
%% @doc
%% Determines if this backend is suitable for receiving traffic, based
%% on whether the failure threshold has been crossed.
%% @end
%%--------------------------------------------------------------------
-spec(is_open(Now :: integer(), _BackendTracking :: #backend_tracking{}) -> boolean()).
is_open(_Now, #backend_tracking{consecutive_failures = Failures,
                          max_failure_threshold = Threshold}) when Failures < Threshold ->
  true;
is_open(Now, #backend_tracking{last_failure_time = Last,
                          failure_backoff = Backoff}) ->
  (Now - Last) > Backoff.

-spec(is_open(BackendTracking :: #backend_tracking{}) -> boolean()).
is_open(BackendTracking) ->
  Now = erlang:monotonic_time(),
  is_open(Now, BackendTracking).


%%--------------------------------------------------------------------
%% @doc
%% Records failure and success statistics for a backend.
%% @end
%%--------------------------------------------------------------------
-spec(track_success(boolean(), BT :: #backend_tracking{}) -> #backend_tracking{}).
track_success(true, BT = #backend_tracking{total_successes = TotalSuccesses}) ->
  BT#backend_tracking{total_successes = TotalSuccesses + 1,
    consecutive_failures = 0};
track_success(false, BT = #backend_tracking{total_failures = TotalFailures,
  consecutive_failures = ConsecutiveFailures}) ->
  Now = erlang:monotonic_time(nano_seconds),
  BT#backend_tracking{total_failures = TotalFailures + 1,
    consecutive_failures = ConsecutiveFailures + 1,
    last_failure_time = Now};
track_success(no_success_change, BT) ->
  BT.


-spec(increment_pending(#ewma{}) -> #ewma{pending :: non_neg_integer()}).
increment_pending(Ewma = #ewma{pending = Pending}) ->
  Ewma#ewma{pending = Pending + 1}.

-spec(decrement_pending(atom(), #ewma{}) -> #ewma{pending :: non_neg_integer()}).
decrement_pending(no_success_change, Ewma) ->
  Ewma;
decrement_pending(_Success, Ewma = #ewma{pending = Pending}) when Pending > 0 ->
  Ewma#ewma{pending = Pending - 1};
decrement_pending(_, Ewma) ->
  lager:warning("Call to decrement connections for backend when pending connections == 0"),
  Ewma.


pick_backend_internal(BackendAddrs) when length(BackendAddrs) > ?BACKEND_LIMIT ->
  minuteman_metrics:update([probabilistic_backend_picker], 1, spiral),
  Now = erlang:monotonic_time(),
  ReachabilityCache = dict:new(),
  Choice = probabilistic_backend_chooser(Now, ReachabilityCache, BackendAddrs, [], [], []),
  {ok, Choice};


pick_backend_internal(BackendAddrs) ->
  minuteman_metrics:update([simple_backend_picker], 1, spiral),
  %% Pull backends out of ets.
  Now = erlang:monotonic_time(),
  Backends = [get_ewma_or_default(Backend) || Backend <- BackendAddrs],

  {Up, Down} = lists:partition(fun (#backend{tracking = Tracking}) ->
    is_open(Now, Tracking)
                               end, Backends),

  % If there are no backends up, may as well try one that's down.
  Choices = case Up of
              [] ->
                Down;
              _ ->
                Up
            end,
  {ReachableTrue, ReachableFalse} = lists:partition(
    fun(Backend) ->
      {IP, _Port} = Backend#backend.ip_port,
      is_reachable_real(IP)
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
  Idx = random:uniform(Size),
  Item = lists:nth(Idx, List),
  {L1, [_|L2]} = lists:split(Idx-1, List),
  ListPrime = L1 ++ L2,
  {ListPrime, Item}.


-spec(probabilistic_backend_chooser(Now :: integer(),
  ReachabilityCache :: dict:dict(),
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
  Backend = get_ewma_or_default(Item),
  Tracking = Backend#backend.tracking,
  {IP, _Port} = Backend#backend.ip_port,
  {ReachabilityCache1, Reachable} = is_reachable(ReachabilityCache, IP),
  IsOpen = is_open(Now, Tracking),
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


is_reachable(ReachabilityCache, IP) ->
  case dict:find(IP, ReachabilityCache) of
    {ok, Value} ->
      {ReachabilityCache, Value};
    _ ->
      Reachable = is_reachable_real(IP),
      ReachabilityCache1 = dict:store(IP, Reachable, ReachabilityCache),
      {ReachabilityCache1, Reachable}
  end.

%% Don't crash if lashup is broken
is_reachable_real(IP) ->
  case catch ets:lookup(reachability_cache, IP) of
    [{IP, true}] ->
      true;
    _ ->
      false
  end.

get_ewma_or_default({IP, Port}) ->
  case ets:lookup(connection_ewma, {IP, Port}) of
    [ExistingBackend] ->
      ExistingBackend;
    [] ->
      #backend{ip_port = {IP, Port}}
  end.

now() ->
  erlang:monotonic_time(nano_seconds).

-ifdef(TEST).

-record(test_state, {known_vips = sets:new()}).

stop() ->
  gen_server:call(?MODULE, clear),
  gen_server:stop(?MODULE).

setup_ets() ->
  reachability_cache = ets:new(reachability_cache, [set, named_table, {read_concurrency, true}]).
stop_ets() ->
  true = ets:delete(reachability_cache).

proper_test() ->
  [] = proper:module(?MODULE).


%% Properties of EWMA:
%%  * weight increases with pending
%%  * when new or completely cold, has a high cost
%%  * cost drops with low observations
%%  * cost rises with high observations

ewma() ->
  ?LET({Cost, Pending},
       {non_neg_integer(), pos_integer()},
       #ewma{cost = Cost, pending = Pending}).

prop_ewma_cost_increases_with_pending() ->
  ?FORALL({Higher, Lower, Ewma},
          ?SUCHTHAT({Higher, Lower, _Ewma},
                    {non_neg_integer(), non_neg_integer(), ewma()},
                    Higher > Lower),
          ewma_cost_increases_with_pending(Higher, Lower, Ewma)).

ewma_cost_increases_with_pending(Higher, Lower, Ewma) ->
  Now = erlang:monotonic_time(nano_seconds),
  [BackendA, BackendB] = lists:map(fun (I) ->
                                       #backend{ewma = Ewma#ewma{pending = I},
                                                ip_port = {{0, 0, 0, 0}, 0},
                                                clock = fun () -> Now end}
                                   end, [Higher, Lower]),
  %% We use inclusive bounds on both ends because large numbers
  %% (penalty is 1.0e307) will compare like this:
  %%    > 1.0e307 + 1 =:= 1.0e307.
  %%    true
  cost(BackendA) >= cost(BackendB).

prop_ewma_cost_decreases_with_time() ->
  ?FORALL({Higher, Lower, Ewma},
          ?SUCHTHAT({Higher, Lower, _Ewma},
                    {non_neg_integer(), non_neg_integer(), ewma()},
                    Higher > Lower),
          ewma_cost_decreases_with_time(Higher, Lower, Ewma)).

ewma_cost_decreases_with_time(Higher, Lower, Ewma) ->
  [BackendA, BackendB] = lists:map(fun (I) ->
                                       #backend{ewma = Ewma,
                                                ip_port = {{0, 0, 0, 0}, 0},
                                                clock = fun () -> I end}
                                   end, [Higher, Lower]),
  cost(BackendA) =< cost(BackendB).

prop_ewma_cost_decreases_with_low_measurements() ->
  ?FORALL(Ewma, ewma(), ewma_cost_decreases_with_low_measurements(Ewma)).

ewma_cost_decreases_with_low_measurements(Ewma) ->
  Backend = #backend{ewma = Ewma, ip_port = {{0, 0, 0, 0}, 0}},
  Clock = Backend#backend.clock,
  Initial = cost(Backend),
  Later = lists:foldl(fun (_E, AccIn) ->
                          observe_internal(0, Clock(), AccIn)
                      end,
                      Ewma,
                      lists:seq(1, 10)),
  cost(#backend{ewma = Later, ip_port = {{0, 0, 0, 0}, 0}}) =< Initial.

prop_ewma_cost_increases_with_high_measurements() ->
  ?FORALL(Ewma, ewma(), ewma_cost_increases_with_high_measurements(Ewma)).

ewma_cost_increases_with_high_measurements(InitialEwma) ->
  Ewma = InitialEwma#ewma{penalty = 0},
  Backend = #backend{ewma = Ewma, ip_port = {{0, 0, 0, 0}, 0}},
  Clock = Backend#backend.clock,
  Initial = cost(Backend),
  Higher = lists:foldl(fun (_E, AccIn) ->
                          observe_internal(2.0e9, Clock(), AccIn)
                      end,
                      Ewma,
                      lists:seq(1, 10)),
  cost(#backend{ewma = Higher, ip_port = {{0, 0, 0, 0}, 0}}) > Initial.

initial_state() ->
  #test_state{}.

prop_server_works_fine() ->
  ?FORALL(Cmds, commands(?MODULE),
          ?TRAPEXIT(
             begin
               setup_ets(),
               ?MODULE:start_link(),
               {History, State, Result} = run_commands(?MODULE, Cmds),
               ?MODULE:stop(),
               stop_ets(),
               ?WHENFAIL(io:format("History: ~w\nState: ~w\nResult: ~w\n",
                                   [History, State, Result]),
                         Result =:= ok)
             end)).

precondition(_, _) -> true.

postcondition(_S, {call, _, pick_backend, [Vips]}, Result) ->
  pick_backend_postcondition(Vips, Result);
postcondition(_, _, _) -> true.

pick_backend_postcondition([], {error, no_backends_available}) ->
  true;
pick_backend_postcondition(Vips, {ok, #backend{ip_port = {IP, Port}}}) ->
  lists:member({IP, Port}, Vips);
pick_backend_postcondition(_, _) ->
  false.


next_state(#test_state{known_vips = KnownVips}, _V, {call, _, observe, [_Measurement, Vip, _Success]}) ->
  #test_state{known_vips = sets:add_element(Vip, KnownVips)};
next_state(#test_state{known_vips = KnownVips}, _V, {call, _, set_pending, [Vip]}) ->
  #test_state{known_vips = sets:add_element(Vip, KnownVips)};
next_state(S, _V, {call, _, pick_backend, [_Vips]}) ->
  S;
next_state(S, _, _) ->
  S.

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
  oneof([{call, ?MODULE, observe, [float(), ip_port(), boolean_or_no_success()]},
         {call, ?MODULE, set_pending, [ip_port()]}] ++
        [{call, ?MODULE, pick_backend, [list(oneof(Vips))]} || VipsPresent]).

state_test() ->
  TestTuple = {{1, 2, 3, 4}, 5000},
  {ok, State} = init([]),
  ?assertEqual([], ets:lookup(connection_ewma, TestTuple)),
  {noreply, State} = handle_cast({set_pending, TestTuple}, State),
  ?assertNotEqual([], ets:lookup(connection_ewma, TestTuple)),
  Backend = get_ewma_or_default(TestTuple),
  EWMA = Backend#backend.ewma,
  ?assertEqual(1, EWMA#ewma.pending),
  ets:delete(connection_ewma).

-endif.
