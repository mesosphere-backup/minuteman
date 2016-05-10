%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Feb 2016 3:14 PM
%%%-------------------------------------------------------------------
-module(minuteman_lashup_publish).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).
-type state() :: #state{}.

-include("minuteman_lashup.hrl").
-include_lib("kernel/include/inet.hrl").

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
  State = #state{},
  gen_server:cast(self(), check_metadata),
  {ok, State}.

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
handle_cast(check_metadata, State) ->
  check_metadata(),
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
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
  {noreply, NewState :: state()} |
  {noreply, NewState :: state(), timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: state()}).
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


check_metadata() ->
  LashupNode = minuteman_config:lashup_node(),
  NodeMetadata = lashup_kv:value(LashupNode, [node_metadata, node()]),
  NodeMetadataDict = orddict:from_list(NodeMetadata),
  Ops = check_ip(NodeMetadataDict, []),
  Ops1 = check_node_id(NodeMetadata, Ops),
  lager:debug("Performing ops: ~p", [Ops]),
  perform_ops(Ops1).

perform_ops([]) ->
  ok;
perform_ops(Ops) ->
  LashupNode = minuteman_config:lashup_node(),
  {ok, _} = lashup_kv:request_op(LashupNode, [node_metadata, node()], {update, Ops}).


check_node_id(NodeMetadata, Ops) ->
  ID = node(),
  check_node_id(ID, NodeMetadata, Ops).

check_node_id(ID, NodeMetadata, Ops) ->
  case orddict:find(?ID_FIELD, NodeMetadata) of
    {ok, ID} ->
      Ops;
    _ ->
      [{update, ?ID_FIELD, {assign, ID, erlang:system_time(nano_seconds)}}|Ops]
  end.

check_ip(NodeMetadata, Ops) ->
  IP = get_ip(),
  check_ip(IP, NodeMetadata, Ops).

check_ip(IP, NodeMetadata, Ops) ->
  case orddict:find(?IP_FIELD, NodeMetadata) of
    {ok, IP} ->
      Ops;
    _ ->
      set_ip(IP, Ops)
  end.

set_ip(IP, Ops) ->
  [{update, ?IP_FIELD, {assign, IP, erlang:system_time(nano_seconds)}}|Ops].


get_ip() ->
  case get_dcos_ip() of
    false ->
      infer_ip();
    IP ->
      IP
  end.

infer_ip() ->
  ForeignIP = get_foreign_ip(),
  {ok, Socket} = gen_udp:open(0),
  inet_udp:connect(Socket, ForeignIP, 4),
  {ok, {Address, _LocalPort}} = inet:sockname(Socket),
  gen_udp:close(Socket),
  Address.

get_foreign_ip() ->
  case inet:gethostbyname("leader.mesos") of
    {ok, Hostent} ->
      [Addr | _] = Hostent#hostent.h_addr_list,
      Addr;
    _ ->
      {192, 88, 99, 0}
  end.


%% Regex borrowed from:
%% http://stackoverflow.com/questions/12794358/how-to-strip-all-blank-characters-in-a-string-in-erlang
-spec(get_dcos_ip() -> false | inet:ip4_address()).
get_dcos_ip() ->
  String = os:cmd("/opt/mesosphere/bin/detect_ip"),
  String1 = re:replace(String, "(^\\s+)|(\\s+$)", "", [global, {return, list}]),
  case inet:parse_ipv4_address(String1) of
    {ok, IP} ->
      IP;
    {error, einval} ->
      false
  end.

