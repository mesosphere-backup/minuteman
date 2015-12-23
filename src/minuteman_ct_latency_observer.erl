%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_ct_latency_observer).
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

-define(RCVBUF_DEFAULT, 212992).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {socket = erlang:error() :: gen_socket:socket()}).

-record(ct_timer, {
  id :: integer(),
  timer_id :: timer:tref(),
  start_time :: integer()
  }).

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
  ets:new(connection_timers, [{keypos, #ct_timer.id}, named_table]),
  {ok, Socket} = socket(netlink, raw, ?NETLINK_NETFILTER, []),
  {gen_socket, RealPort, _, _, _, _} = Socket,
  erlang:link(RealPort),
  ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_RCVBUF, 57108864),
  ok = gen_socket:setsockopt(Socket, ?SOL_NETLINK, ?NETLINK_ADD_MEMBERSHIP, ?NFNLGRP_CONNTRACK_NEW),
  ok = gen_socket:setsockopt(Socket, ?SOL_NETLINK, ?NETLINK_ADD_MEMBERSHIP, ?NFNLGRP_CONNTRACK_UPDATE),
  netlink:rcvbufsiz(Socket, ?RCVBUF_DEFAULT),
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
handle_info({check_conn_connected, {ID, IP, Port}}, State) ->
  case ets:take(connection_timers, ID) of
    [#ct_timer{timer_id = TimerID, start_time = StartTime}] ->
      TimeDelta = erlang:monotonic_time(nano_seconds) - StartTime,
      timer:cancel(TimerID),
      Success = false,
      minuteman_ewma:observe(TimeDelta,
                             {IP, Port},
                             Success);
    _ ->
      % we've already cleared it
      ok
  end,
  {noreply, State};
handle_info({Socket, input_ready}, State = #state{socket = Socket}) ->
  case gen_socket:recv(Socket, 8192) of
    {ok, Data} ->
      Msg = netlink:nl_ct_dec(Data),
      lists:foreach(fun handle_conn/1, Msg);
    Other ->
      lager:warning("Unknown msg (ct_latency): ~p", [Other])
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

handle_conn(#ctnetlink{msg = {_Family, _, _, Props}}) ->
  {id, ID} = proplists:lookup(id, Props),
  {status, Status} = proplists:lookup(status, Props),
  {tuple_reply, Reply} = proplists:lookup(tuple_reply, Props),
  Addresses = fmt_net(Reply),
  mark_replied(ID, Addresses, Status).

mark_replied(ID, {_Proto, DstIP, DstPort, _SrcIP, _SrcPort}, Status) ->
  case lists:member(seen_reply, Status) of
    true ->
      lager:debug("marking backend ~p:~p available", [DstIP, DstPort]),
      case ets:take(connection_timers, ID) of
        [#ct_timer{timer_id = TimerID, start_time = StartTime}] ->
          TimeDelta = erlang:monotonic_time(nano_seconds) - StartTime,
          timer:cancel(TimerID),
          Success = true,
          minuteman_ewma:observe(TimeDelta,
                                 {DstIP, DstPort},
                                 Success);
        _ ->
          % we've already cleared it, or we never saw its initial SYN
          ok
      end;
    false ->
      minuteman_ewma:set_pending({DstIP, DstPort}),
      lager:debug("marking backend ~p:~p in-flight", [DstIP, DstPort]),
      % Set up a timer and schedule a connection check at the
      % configured threshold.
      {ok, TimerID} = timer:send_after(minuteman_config:tcp_connect_threshold(),
                                       {check_conn_connected, {ID, DstIP, DstPort}}),
      ets:insert(connection_timers, #ct_timer{id = ID,
                                              timer_id = TimerID,
                                              start_time = erlang:monotonic_time(nano_seconds)})
  end;
mark_replied(_, _, _) ->
  %% unsupported proto (udp, icmp, sctp...)
  ok.

fmt_net(Props) ->
  {ip, IPProps} = proplists:lookup(ip, Props),

  {v4_src, SrcIP} = proplists:lookup(v4_src, IPProps),
  {v4_dst, DstIP} = proplists:lookup(v4_dst, IPProps),

  {proto, ProtoProps} = proplists:lookup(proto, Props),

  {num, Proto} = proplists:lookup(num, ProtoProps),

  case Proto of
    tcp ->
      {src_port, SrcPort} = proplists:lookup(src_port, ProtoProps),
      {dst_port, DstPort} = proplists:lookup(dst_port, ProtoProps),
      {Proto, SrcIP, SrcPort, DstIP, DstPort};
    _ ->
      {error, unsupported_proto}
  end.
