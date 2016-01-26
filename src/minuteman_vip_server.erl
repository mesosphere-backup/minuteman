%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 9:15 PM
%%%-------------------------------------------------------------------
-module(minuteman_vip_server).
-author("sdhillon").
-author("Tyler Neely").

-behaviour(gen_server).

%% API
-export([stop/0, start_link/0, push_vips/1, get_backend/1, get_backend/2, get_vips/0,
  get_backends_for_vip/2, get_backends_for_vip/1, push_vips_sync/1, start_link_nosubscribe/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-include("minuteman.hrl").

-ifdef(TEST).
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-export([initial_state/0, command/1, precondition/2, postcondition/3, next_state/3]).
-endif.

-define(SERVER, ?MODULE).

-record(state, {}).


%%%===================================================================
%%% API
%%%===================================================================
get_backend(IP, Port) ->
  get_backend({IP, Port}).
get_backend({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
  %% We assume, and only support tcp right now
  case catch ets:lookup(vips, {tcp, IP, Port}) of
    [] ->
      %% This should never happen, but it's better than crashing
      error;
    [{_Key, Backends}] when is_list(Backends) ->
      case minuteman_ewma:pick_backend(Backends) of
        {ok, Backend} ->
          {ok, Backend#backend.ip_port};
        {error, Reason} ->
          lager:warning("failed to retrieve backend for vip {tcp, ~p, ~B}: ~p", [IP, Port, Reason]),
          error
      end;
    Error ->
      lager:warning("failed to retrieve backend for vip {tcp, ~p, ~B}: ~p", [IP, Port, Error]),
      error
  end.


push_vips_sync(Vips) ->
  lager:debug("Pushing Vips: ~p", [Vips]),
  gen_server:call(?SERVER, {push_vips, Vips}),
  ok.

push_vips(Vips) ->
  lager:debug("Pushing Vips: ~p", [Vips]),
  gen_server:cast(?SERVER, {push_vips, Vips}),
  ok.

get_vips() ->
  gen_server:call(?SERVER, get_vips).

get_backends_for_vip(IP, Port) ->
  get_backends_for_vip({IP, Port}).

get_backends_for_vip({IP, Port})  when is_tuple(IP) andalso is_integer(Port)  ->
  gen_server:call(?SERVER, {get_backends_for_vip, {IP, Port}}).

stop() ->
  gen_server:call(?MODULE, stop).

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
start_link_nosubscribe() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [nosubscribe], []).


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
  setup(),
  minuteman_vip_events:add_sup_handler(fun push_vips/1),
  {ok, #state{}};
init([nosubscribe]) ->
  setup(),
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
handle_call({push_vips, Vips}, _From, State) ->
  handle_push_vips(Vips),
  {reply, ok, State};
handle_call(get_vips, _From, State = #state{}) ->
  Vips = handle_get_vips(),
  {reply, Vips, State};
handle_call({get_backends_for_vip, {Ip, Port}}, _From, State) ->
  Backends = handle_backends_for_vip(Ip, Port),
  {reply, Backends, State};
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
handle_cast({push_vips, Vips}, State) ->
  handle_push_vips(Vips),
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
handle_get_vips() ->
  orddict:from_list(ets:tab2list(vips)).

handle_push_vips(Vips) ->
  CurrentVIPs = ets:foldl(fun({Key, _Value}, Acc) -> [Key|Acc] end, [], vips),
  Keys = orddict:fetch_keys(Vips),
  KeysSet = ordsets:from_list(Keys),
  CurrentVIPsSet = ordsets:from_list(CurrentVIPs),
  VipsToDelete = ordsets:subtract(CurrentVIPsSet, KeysSet),
  [true = ets:delete(vips, Key) || Key <- VipsToDelete],
  [true = ets:insert(vips, Vip) || Vip <- Vips].

-spec(handle_backends_for_vip(inet:ip4_address(), inet:port_number()) -> term()).
handle_backends_for_vip(IP, Port) ->
  case ets:lookup(vips, {tcp, IP, Port}) of
    [{_Vip, Backends}] ->
      {ok, Backends};
    _ ->
      error
  end.

setup() ->
  vips = ets:new(vips, [named_table, set, {read_concurrency, true}]),
  %% 16MB,
  process_flag(min_heap_size, 2000000),
  process_flag(priority, low).

-ifdef(TEST).
-compile(export_all).


-record(test_state, {vips}).

proper_test_() ->
  {timeout, 60, [fun() -> [] = proper:module(?MODULE, [{numtests, 100}]) end]}.

initial_state() ->
  #test_state{vips = []}.

prop_server_works_fine() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
                begin
                    ?MODULE:start_link_nosubscribe(),
                    {History, State, Result} = run_commands(?MODULE, Cmds),
                    gen_server:stop(?MODULE),
                    ?WHENFAIL(io:format("History: ~w\nState: ~w\nResult: ~w\n",
                                        [History, State, Result]),
                              Result =:= ok)
                end)).

precondition(_, _) -> true.

postcondition(_State  = #test_state{vips = VIPs}, {call, _, get_backends_for_vip, [VIP]}, Result) ->
  case orddict:find(VIP, VIPs) of
    error ->
      Result == error;
    {ok, Backends} ->
      Result == Backends
  end;
postcondition(_State  = #test_state{vips = VIPs}, {call, _, get_vips, []}, Result) ->
  orddict:from_list(VIPs) == orddict:from_list(Result);
postcondition(_, _, _) -> true.

next_state(S, _V, {call, _, push_vips_sync, [VIPs]}) ->
      S#test_state{vips = VIPs};
next_state(S, _, _) ->
  S.

ip() ->
  ?LET({I1, I2, I3, I4},
       {integer(0, 255), integer(0, 255), integer(0, 255), integer(0, 255)},
       {I1, I2, I3, I4}).

port() ->
  ?LET(Port, integer(0, 65535), Port).

ip_port() ->
  ?LET({IP, Port},
       {ip(), port()},
       {IP, Port}).

vip() ->
  ?LET({{tcp, IP, Port}, Backends}, {{tcp, ip(), port()}, non_empty(list(ip_port()))}, {{tcp, IP, Port}, Backends}).

merge(Dict, []) ->
  Dict;
merge(Dict, [VipBackend|VipsBackends]) ->
  Dict1 = orddict:merge(fun(_Key, V1, V2) -> lists:usort(V1 ++ V2) end, Dict, VipBackend),
  merge(Dict1, VipsBackends).

merge(VipsBackends) ->
  merge([], VipsBackends).

vip_foldfun(VipsBackends) ->
  merge(VipsBackends).
vips() ->
  ?LET(VIPsBackends, list(vip()), vip_foldfun([VIPsBackends])).

%% This only works right now because all VIP server state is in ets
%% the reason behind calling handle_cast directly is to solve the async problem
command(_S) ->
    oneof([{call, ?MODULE, get_backend, [ip_port()]},
           {call, ?MODULE, push_vips_sync, [vips()]},
           {call, ?MODULE, get_vips, []},
           {call, ?MODULE, get_backends_for_vip, [ip_port()]}]).

-endif.
