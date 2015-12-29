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
  pick_backend/1
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
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {}).

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
  gen_server:call(?SERVER, {pick_backend, Backends}, 100).

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
  random:seed(erlang:phash2([node()]),
              erlang:monotonic_time(),
              erlang:unique_integer()),
  ets:new(connection_ewma, [{keypos, #backend.ip_port}, named_table]),
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
  NewEwma =  decrement_pending(ObservedEwma),

  Tracking = Backend#backend.tracking,
  NewTracking = track_success(Success, Tracking),

  NewBackend = Backend#backend{ewma = NewEwma,
                              tracking = NewTracking},
  ets:insert(connection_ewma, NewBackend),
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
cost(#backend{clock = Clock, ewma = Ewma}) ->
  % We observe 0 here to slide the exponential window forward by the
  % amount of time that has passed since the last measurement.
  #ewma{cost = Cost, pending = Pending, penalty = Penalty} = observe_internal(0.0, Clock(), Ewma),
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
-spec(is_open(_BackendTracking :: #backend_tracking{}) -> boolean()).
is_open(#backend_tracking{consecutive_failures = Failures,
                          max_failure_threshold = Threshold}) when Failures < Threshold ->
  true;
is_open(#backend_tracking{last_failure_time = Last,
                          failure_backoff = Backoff}) ->
  Now = erlang:monotonic_time(nano_seconds),
  (Now - Last) > Backoff.

%%--------------------------------------------------------------------
%% @doc
%% Records a failure, to be counted against the max_failure_threshold.
%% @end
%%--------------------------------------------------------------------
-spec(track_success(boolean(), #backend_tracking{}) -> #backend_tracking{}).
track_success(true, Tracking) ->
  add_success(Tracking);
track_success(false, Tracking) ->
  add_failure(Tracking).

%%--------------------------------------------------------------------
%% @doc
%% Records a failure, to be counted against the max_failure_threshold.
%% @end
%%--------------------------------------------------------------------
-spec(add_failure(BT :: #backend_tracking{}) -> #backend_tracking{}).
add_failure(BT = #backend_tracking{consecutive_failures = Failures}) ->
  Now = erlang:monotonic_time(nano_seconds),
  BT#backend_tracking{consecutive_failures = Failures + 1,
                      last_failure_time = Now}.

%%--------------------------------------------------------------------
%% @doc
%% Records a success, resetting consecutive_failures to 0.
%% @end
%%--------------------------------------------------------------------
-spec(add_success(BT :: #backend_tracking{}) -> #backend_tracking{}).
add_success(BT = #backend_tracking{}) ->
  BT#backend_tracking{consecutive_failures = 0}.

-spec(increment_pending(#ewma{}) -> #ewma{pending :: non_neg_integer()}).
increment_pending(Ewma = #ewma{pending = Pending}) ->
  Ewma#ewma{pending = Pending + 1}.

-spec(decrement_pending(#ewma{}) -> #ewma{pending :: non_neg_integer()}).
decrement_pending(Ewma = #ewma{pending = Pending}) when Pending > 0 ->
  Ewma#ewma{pending = Pending - 1};
decrement_pending(Ewma) ->
  lager:warning("Call to decrement connections for backend when pending connections == 0"),
  Ewma.

pick_backend_internal(BackendAddrs) ->
  %% Pull backends out of ets.
  Backends = lists:map(fun get_ewma_or_default/1, BackendAddrs),
  {Up, Down} = lists:partition(fun (#backend{tracking = Tracking}) ->
                                   is_open(Tracking)
                               end, Backends),

  % If there are no backends up, may as well try one that's down.
  Choices = case Up of
              [] ->
                Down;
              _ ->
                Up
            end,

  % If there's only one choice, use it.  Otherwise, try to get two
  % different random selections and pick the one with the better
  % cost.
  case Choices of
    [Choice] ->
      {ok, Choice};
    _ ->
      Size = length(Choices),
      A = rand:uniform(Size),
      B = try_different_rand(Size, A, 10),

      BackendA = lists:nth(A, Choices),
      BackendB = lists:nth(B, Choices),

      Choice = choose_backend_by_cost(BackendA, BackendB),
      {ok, Choice}
  end.

-spec(choose_backend_by_cost(#backend{}, #backend{}) -> #backend{}).
choose_backend_by_cost(A, B) ->
  case cost(A) < cost(B) of
    true -> A;
    false -> B
  end.

-spec(try_different_rand(integer(), integer(), integer()) -> integer()).
try_different_rand(_Max, Other, 0) ->
  Other;
try_different_rand(Max, Other, TriesLeft) ->
  case rand:uniform(Max) of
    Other ->
      try_different_rand(Max, Other, TriesLeft - 1);
    R ->
      R
  end.

get_ewma_or_default({IP, Port}) ->
  case ets:lookup(connection_ewma, {IP, Port}) of
    [{_Addr, ExistingBackend}] ->
      ExistingBackend;
    _ ->
      #backend{ip_port = {IP, Port}}
  end.

-ifdef(TEST).

-record(test_state, {known_vips = sets:new()}).

stop() ->
  gen_server:call(?MODULE, clear).

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
                                                clock = fun () -> I end}
                                   end, [Higher, Lower]),
  cost(BackendA) =< cost(BackendB).

prop_ewma_cost_decreases_with_low_measurements() ->
  ?FORALL(Ewma, ewma(), ewma_cost_decreases_with_low_measurements(Ewma)).

ewma_cost_decreases_with_low_measurements(Ewma) ->
  Backend = #backend{ewma = Ewma},
  Clock = Backend#backend.clock,
  Initial = cost(Backend),
  Later = lists:foldl(fun (_E, AccIn) ->
                          observe_internal(0, Clock(), AccIn)
                      end,
                      Ewma,
                      lists:seq(1, 10)),
  cost(#backend{ewma = Later}) =< Initial.

prop_ewma_cost_increases_with_high_measurements() ->
  ?FORALL(Ewma, ewma(), ewma_cost_increases_with_high_measurements(Ewma)).

ewma_cost_increases_with_high_measurements(InitialEwma) ->
  Ewma = InitialEwma#ewma{penalty = 0},
  Backend = #backend{ewma = Ewma},
  Clock = Backend#backend.clock,
  Initial = cost(Backend),
  Higher = lists:foldl(fun (_E, AccIn) ->
                          observe_internal(2.0e9, Clock(), AccIn)
                      end,
                      Ewma,
                      lists:seq(1, 10)),
  cost(#backend{ewma = Higher}) > Initial.

initial_state() ->
  #test_state{}.

prop_server_works_fine() ->
  ?FORALL(Cmds, commands(?MODULE),
          ?TRAPEXIT(
             begin
               ?MODULE:start_link(),
               {History, State, Result} = run_commands(?MODULE, Cmds),
               ?MODULE:stop(),
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


command(S) ->
  Vips = sets:to_list(S#test_state.known_vips),
  VipsPresent = (Vips =/= []),
  oneof([{call, ?MODULE, observe, [float(), ip_port(), boolean()]},
         {call, ?MODULE, set_pending, [ip_port()]}] ++
        [{call, ?MODULE, pick_backend, [list(oneof(Vips))]} || VipsPresent]).

-endif.
