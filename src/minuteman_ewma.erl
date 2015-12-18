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
-export([start_link/0]).
-export([observe/3,
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


-include("enfhackery.hrl").

-define(SERVER, ?MODULE).

-record(state, {i}).

%%%===================================================================
%%% API
%%%===================================================================
observe(Time, {IP, Port}, Success) ->
  gen_server:cast(?SERVER, {observe, {Time, {IP, Port}, Success}}).

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
-spec(pick_backend(list(#backend{})) -> {ok, #backend{}} | {error, string()}).
pick_backend([]) ->
  {error, "No backends available."};
pick_backend(Backends) ->
  gen_server:call(?SERVER, {pick_backend, Backends}).

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
  ets:new(connection_ewma, [public, named_table]),
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
handle_cast({observe, {Time, {IP, Port}, Success}}, State) ->
  lager:debug("Observing connection success: ~p with time of ~p ms", [Success, Time / 1.0e6]),
  Backend = get_ewma_or_default({IP, Port}),
  Ewma = Backend#backend.ewma,
  ObservedEwma = observe(Time, Ewma),
  NewEwma =  decrement_pending(ObservedEwma),

  Tracking = Backend#backend.tracking,
  NewTracking = track_success(Success, Tracking),

  NewBackend = Backend#backend{ewma = NewEwma,
                              tracking = NewTracking},
  ets:insert(connection_ewma, {{IP, Port}, NewBackend}),
  {noreply, State};

handle_cast({set_pending, {IP, Port}}, State) ->
  Backend = get_ewma_or_default({IP, Port}),
  NewEwma = increment_pending(Backend#backend.ewma),
  NewBackend = Backend#backend{ewma = NewEwma},
  ets:insert(connection_ewma, {{IP, Port}, NewBackend}),
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
-spec(observe(Val :: float(), _Ewma :: #ewma{}) -> #ewma{}).
observe(Val, Ewma = #ewma{cost = Cost,
                          stamp = Stamp,
                          decay = Decay}) ->
  Now = os:system_time(),
  TD = max(Now - Stamp, 0),
  W = math:exp(-TD / Decay),
  NewCost = case Val > Cost of
              true -> Val;
              false -> (Cost * W) + (Val * (1.0-W))
            end,
  Ewma#ewma{stamp = Now, cost = NewCost}.

%%--------------------------------------------------------------------
%% @doc
%% Returns the cost of this according to the EWMA algorithm.
%% @end
%%--------------------------------------------------------------------
-spec(cost(#backend{}) -> float()).
cost(#backend{ewma = Ewma}) ->
  % We observe 0 here to slide the exponential window forward by the
  % amount of time that has passed since the last measurement.
  #ewma{cost = Cost, pending = Pending, penalty = Penalty} = observe(0.0, Ewma),
  case {Cost, Penalty} of
    {0, P} when P /= 0 ->
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
  Now = os:system_time(),
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
  Now = os:system_time(),
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
increment_pending(Ewma = #ewma{pending = Pending}) when Pending >= 0 ->
  Ewma#ewma{pending = Pending + 1}.

-spec(decrement_pending(#ewma{}) -> #ewma{pending :: non_neg_integer()}).
decrement_pending(Ewma = #ewma{pending = Pending}) when Pending >= 0 ->
  Ewma#ewma{pending = Pending - 1}.

pick_backend_internal(BackendAddrs) ->
  %% Pull backends out of ets.
  Backends = lists:map(fun get_ewma_or_default/1, BackendAddrs),
  {Up, Down} = lists:partition(fun (#backend{tracking = Tracking}) ->
                                   is_open(Tracking)
                               end, Backends),

  % If there are no backends up, may as well try one that's down.
  Choices = case length(Up) > 0 of
              true -> Up;
              false -> Down
            end,

  % If there's only one choice, use it.  Otherwise, try to get two
  % different random selections and pick the one with the better
  % cost.
  Size = length(Choices),
  case Size of
    1 -> {ok, lists:nth(1, Choices)};
    _ ->
      A = rand:uniform(Size),
      B = try_different_rand(Size, A, 10),

      BackendA = lists:nth(A, Choices),
      BackendB = lists:nth(B, Choices),

      case cost(BackendA) < cost(BackendB) of
        true -> {ok, BackendA};
        false -> {ok, BackendB}
      end
  end.

-spec(try_different_rand(integer(), integer(), integer()) -> integer()).
try_different_rand(_Max, Other, 0) ->
  Other;
try_different_rand(Max, Other, TriesLeft) ->
  R = rand:uniform(Max),
  case R == Other of
    true ->
      try_different_rand(Max, Other, TriesLeft - 1);
    false ->
      R
  end.

get_ewma_or_default({IP, Port}) ->
  case ets:lookup(connection_ewma, {IP, Port}) of
    [{_Addr, ExistingBackend}] ->
      ExistingBackend;
    _ ->
      #backend{ip = IP, port = Port}
  end.
