%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_retry_detector).
-author("Tyler Neely").

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

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-include("enfhackery.hrl").

-define(NFQNL_COPY_PACKET, 2).

-define(NFNLGRP_CONNTRACK_NEW, 1).
-define(NFNLGRP_CONNTRACK_UPDATE, 2).
-define(NFNLGRP_CONNTRACK_DESTROY, 3).
-define(NFNLGRP_CONNTRACK_EXP_NEW, 4).
-define(NFNLGRP_CONNTRACK_EXP_UPDATE, 5).
-define(SOL_NETLINK, 270).
-define(NETLINK_ADD_MEMBERSHIP, 1).

-define(SERVER, ?MODULE).

-record(state, {socket = erlang:error() :: gen_socket:socket()}).

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
-spec(init(term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  ets:new(unreplied_backends, [public, named_table]),
  {ok, Socket} = socket(netlink, raw, ?NETLINK_NETFILTER, []),
  {gen_socket, RealPort, _, _, _, _} = Socket,
  erlang:link(RealPort),
  ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_RCVBUF, 57108864),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_SNDBUF, 57108864),
  ok = gen_socket:setsockopt(Socket, ?SOL_NETLINK, ?NETLINK_ADD_MEMBERSHIP, ?NFNLGRP_CONNTRACK_NEW),
  ok = gen_socket:setsockopt(Socket, ?SOL_NETLINK, ?NETLINK_ADD_MEMBERSHIP, ?NFNLGRP_CONNTRACK_UPDATE),
  ok = gen_socket:input_event(Socket, true),
  {ok, #state{socket = Socket}}.

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
handle_call({handle_mapping, Mapping}, _From, State = #state{socket = Socket}) ->
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
handle_info({Socket, input_ready}, State = #state{socket = Socket}) ->
  case gen_socket:recv(Socket, 8192) of
    {ok, Data} ->
      Msg = netlink:nl_ct_dec(Data),
      lists:map(fun handle_conn/1, Msg);
    Other ->
      lager:warning("Unknown msg (ct): ~p~n", [Other])
  end,
  ok = gen_socket:input_event(Socket, true),
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
  State :: #state{}) -> term()).
terminate(_Reason, _State = #state{socket = Socket}) ->
  gen_socket:close(Socket),
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

socket(Family, Type, Protocol, Opts) ->
  case proplists:get_value(netns, Opts) of
    undefined ->
      gen_socket:socket(Family, Type, Protocol);
    NetNs ->
      gen_socket:socketat(NetNs, Family, Type, Protocol)
  end.

handle_conn(#ctnetlink{type = Type, msg = {inet,_,_,[{tuple_orig,Orig},
                                                     {tuple_reply,Reply},
                                                     {id,ID},
                                                     {status,Status} | _Rest]}}) ->
  mark_replied(fmt_net(Reply), Status),
  ok.

mark_replied({_Proto, DstIP, DstPort, _SrcIP, _SrcPort}, Status) ->
  case lists:member(seen_reply, Status) of
    true ->
      lager:debug("marking backend ~p:~p available", [DstIP, DstPort]),
      ets:delete(unreplied_backends, {DstIP, DstPort});
    false ->
      lager:debug("marking backend ~p:~p in-flight", [DstIP, DstPort]),
      ets:update_counter(unreplied_backends, {DstIP, DstPort}, 1, {{DstIP, DstPort}, 0})
  end.

fmt_net([{ip,
         [{v4_src,SrcIP},
          {v4_dst,DstIP}]},
        {proto,
         [{num,Proto},
          {src_port,SrcPort},
          {dst_port,DstPort}]}]) ->
  {Proto, SrcIP, SrcPort, DstIP, DstPort}.
