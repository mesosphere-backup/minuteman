%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Feb 2016 3:14 PM
%%%-------------------------------------------------------------------
-module(minuteman_lashup_index).
-author("sdhillon").

-behaviour(gen_server).

-dialyzer(no_improper_lists).

%% API
-export([start_link/0,
  nodenames/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-include_lib("stdlib/include/ms_transform.hrl").

-record(state, {
  ref = erlang:error() :: reference()
}).
-type state() :: #state{}.

-include("minuteman_lashup.hrl").

-record(node_ip, {ip, nodename, id}).
-record(node_id, {nodename, id}).


%%%===================================================================
%%% API
%%%===================================================================


nodenames(IP = {_A, _B, _C, _D}) ->
  case ets:lookup(node_ip, IP) of
    [] ->
      [];
    Nodes ->
      Nodes2 = lists:filter(fun matches_id/1, Nodes),
      [Nodename || #node_ip{nodename = Nodename} <- Nodes2]
  end.

matches_id(#node_ip{id = Id, nodename = NodeName}) ->
  case lashup_gm:id(NodeName) of
    Id ->
      true;
    _ ->
      false
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
-spec(init(Args :: term()) ->
  {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  node_ip = ets:new(node_ip, [bag, named_table, {keypos, #node_ip.ip}]),
  node_id = ets:new(node_id, [set, named_table, {keypos, #node_ip.nodename}]),
  LashupNode = minuteman_config:lashup_node(),
  {ok, Ref} = lashup_kv_events_helper:start_link(LashupNode, ets:fun2ms(fun({[node_metadata|_]}) -> true end)),
  {ok, #state{ref = Ref}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: state()) ->
  {reply, Reply :: term(), NewState :: state()} |
  {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
  {stop, Reason :: term(), NewState :: state()}).
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
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
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State = #state{ref = Ref}) when Ref == Reference ->
  handle_event(Event),
  {noreply, State};
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
  State :: state()) -> term()).
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
-spec(code_change(OldVsn :: term() | {down, term()}, State :: state(),
  Extra :: term()) ->
  {ok, NewState :: state()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


%%#{key => Key, map => Map, vclock => VClock, value => Value, ref => Reference},
handle_event(Event = #{type := ingest_update}) ->
  handle_update(Event);
handle_event(Event = #{type := ingest_new}) ->
  handle_new(Event).

handle_new(_Event = #{key := Key, value := Value}) ->
  Value1 = orddict:from_list(Value),
  [node_metadata, Nodename] = Key,
  IP = orddict:fetch(?IP_FIELD, Value1),
  ID = orddict:fetch(?ID_FIELD, Value1),
  ets:insert(node_ip, #node_ip{ip = IP, id = ID, nodename = Nodename}),
  ets:insert(node_id, #node_id{nodename = Nodename, id = ID}).

%% TODO: Refactor
handle_update(_Event = #{key := Key, value := Value, old_value := OldValue}) ->
  Value1 = orddict:from_list(Value),
  OldValue1 = orddict:from_list(OldValue),
  [node_metadata, Nodename] = Key,
  IP = orddict:fetch(?IP_FIELD, Value1),
  ID = orddict:fetch(?ID_FIELD, Value1),
  OldIP = orddict:fetch(?IP_FIELD, OldValue1),
  OldID = orddict:fetch(?ID_FIELD, OldValue1),
  if
    OldIP == IP andalso OldID == ID ->
      ok;
    true ->
      ets:delete_object(node_ip, #node_ip{ip = OldIP, id = OldID, nodename = Nodename})
  end,
  ets:insert(node_ip, #node_ip{ip = IP, id = ID, nodename = Nodename}),
  ets:insert(node_id, #node_id{nodename = Nodename, id = ID}).


