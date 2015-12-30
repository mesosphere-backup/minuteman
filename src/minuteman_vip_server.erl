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
-export([stop/0, start_link/0, push_vips/1, get_backend/1, get_backend/2]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-include("minuteman.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-export([initial_state/0, command/1, precondition/2, postcondition/3, next_state/3]).
-endif.

-define(SERVER, ?MODULE).

-record(state, {vips = dict:new()}).

-type vips() :: dict:dict().

%%%===================================================================
%%% API
%%%===================================================================
get_backend(IP, Port) ->
  get_backend({IP, Port}).
get_backend({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
  catch gen_server:call(?SERVER, {get_backend, IP, Port}, 10).

push_vips(Vips) ->
  lager:debug("Pushing Vips: ~p", [Vips]),
  VipDict = dict:from_list(Vips),
  gen_server:cast(?SERVER, {push_vips, VipDict}),
  ok.

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
  minuteman_vip_events:add_sup_handler(fun push_vips/1),
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
handle_call({get_backend, IP, Port}, _From, State = #state{vips = Vips}) ->
  lager:debug("Looking up VIP: ~p:~B", [IP, Port]),
  {reply, choose_backend(IP, Port, Vips), State};
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
  {noreply, State#state{vips = Vips}};
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

-spec(choose_backend(inet:ip4_address(), inet:port_number(), vips()) -> term()).
choose_backend(IP, Port, Vips) ->
  %% We assume, and only support tcp right now
  case dict:find({tcp, IP, Port}, Vips) of
    {ok, []} ->
      %% This should never happen, but it's better than crashing
      error;
    {ok, Backends} ->
      case minuteman_ewma:pick_backend(Backends) of
        {ok, Backend} ->
          {ok, Backend#backend.ip_port};
        {error, Reason} ->
          lager:warning("failed to retrieve backend for vip {tcp, ~p, ~B}: ~p", [IP, Port, Reason]),
          error
      end;
    error ->
      error
  end.

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
-ifdef(TEST).

proper_test() ->
  [] = proper:module(?MODULE).

initial_state() ->
  #state{vips = dict:new()}.

prop_server_works_fine() ->
    ?FORALL(Cmds, commands(?MODULE),
            ?TRAPEXIT(
                begin
                    minuteman_vip_events:start_link(),
                    ?MODULE:start_link(),
                    {History, State, Result} = run_commands(?MODULE, Cmds),
                    ?MODULE:stop(),
                    gen_server:stop(minuteman_vip_events),
                    ?WHENFAIL(io:format("History: ~w\nState: ~w\nResult: ~w\n",
                                        [History, State, Result]),
                              Result =:= ok)
                end)).

precondition(_, _) -> true.

postcondition(_, _, _) -> true.

next_state(S, _V, {call, _, push_vips, [VIPs]}) ->
      S#state{vips = VIPs};
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

vip() ->
  ?LET({VIP, Backend}, {ip_port(), ip_port()}, {VIP, Backend}).

vips() ->
  ?LET(VIPsBackends, list(vip()), lists:foldl(fun({K, V}, Acc) ->
                                                  orddict:append(K, V, Acc)
                                              end, orddict:new(), VIPsBackends)).
command(_S) ->
    oneof([{call, ?MODULE, get_backend, [ip_port()]},
           {call, ?MODULE, push_vips, [vips()]}]).

-endif.
