%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 05. Dec 2015 11:52 AM
-module(nfq).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% nfq callbacks
-export([nfq_init/1, nfq_verdict/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(SERVER, ?MODULE).

-record(state, {socket, queue, cb, cb_state}).

-define(NFQNL_COPY_PACKET, 2).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Queue) ->
  start_link(Queue, []).

start_link(Queue, Opts) ->
  gen_server:start_link(?MODULE, [Queue, Opts], []).

start_link(ServerName, Queue, Opts) ->
  gen_server:start_link(ServerName, ?MODULE, [Queue, Opts], []).

%%%===================================================================
%%% nfq callbacks
%%%===================================================================
nfq_init(_Opts) ->
  {}.

nfq_verdict(_Family, _Info, _State) ->
  ?NF_ACCEPT.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Queue, Opts]) ->
  {ok, Socket} = socket(netlink, raw, ?NETLINK_NETFILTER, Opts),
  %% ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  gen_socket:getsockname(Socket),

  ok = nfq_unbind_pf(Socket, inet),
  ok = nfq_bind_pf(Socket, inet),
  ok = nfq_create_queue(Socket, Queue),
  ok = nfq_set_mode(Socket, Queue, ?NFQNL_COPY_PACKET, 65535),
  ok = nfq_set_flags(Socket, Queue, [conntrack], [conntrack]),

  ok = gen_socket:input_event(Socket, true),

  Cb = proplists:get_value(cb, Opts, ?MODULE),
  CbState = Cb:nfq_init(Opts),
  {ok, #state{socket = Socket, queue = Queue, cb = Cb, cb_state = CbState}}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({Socket, input_ready}, State = #state{socket = Socket}) ->
  case gen_socket:recv(Socket, 8192) of
    {ok, Data} ->
      Msg = netlink:nl_ct_dec(Data),
      process_nfq_msgs(Msg, State);
    Other ->
      lager:debug("Other: ~p~n", [Other])
  end,
  ok = gen_socket:input_event(Socket, true),
  {noreply, State};

handle_info(Info, State) ->
  lager:warning("got Info: ~p~n", [Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

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

nfnl_query(Socket, Query) ->
  Request = netlink:nl_ct_enc(Query),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request),
  Answer = gen_socket:recv(Socket, 8192),
  lager:debug("Answer: ~p~n", [Answer]),
  case Answer of
    {ok, Reply} ->
      lager:debug("Reply: ~p~n", [netlink:nl_ct_dec(Reply)]),
      case netlink:nl_ct_dec(Reply) of
        [{netlink,error,[],_,_,{ErrNo, _}}|_] when ErrNo == 0 ->
          ok;
        [{netlink,error,[],_,_,{ErrNo, _}}|_] ->
          {error, ErrNo};
        [Msg|_] ->
          {error, Msg};
        Other ->
          Other
      end;
    Other ->
      Other
  end.

build_send_cfg_msg(Socket, Command, Queue, Pf) ->
  Cmd = {cmd, Command, Pf},
  Msg = {queue, config, [ack,request], 0, 0, {unspec, 0, Queue, [Cmd]}},
  nfnl_query(Socket, Msg).

nfq_unbind_pf(Socket, Pf) ->
  build_send_cfg_msg(Socket, pf_unbind, 0, Pf).

nfq_bind_pf(Socket, Pf) ->
  build_send_cfg_msg(Socket, pf_bind, 0, Pf).

nfq_create_queue(Socket, Queue) ->
  build_send_cfg_msg(Socket, bind, Queue, unspec).

nfq_set_mode(Socket, Queue, CopyMode, CopyLen) ->
  Cmd = {params, CopyLen, CopyMode},
  Msg = {queue, config, [ack,request], 0, 0, {unspec, 0, Queue, [Cmd]}},
  nfnl_query(Socket, Msg).

nfq_set_flags(Socket, Queue, Flags, Mask) ->
  Cmd = [{mask, Mask}, {flags, Flags}],
  Msg = {queue, config, [ack,request], 0, 0, {unspec, 0, Queue, Cmd}},
  nfnl_query(Socket, Msg).

process_nfq_msgs([], _State) ->
  ok;
process_nfq_msgs([Msg|Rest], State) ->
  lager:debug("NFQ-Msg: ~p~n", [Msg]),
  process_nfq_msg(Msg, State),
  process_nfq_msgs(Rest, State).

process_nfq_msg({queue, packet, _Flags, _Seq, _Pid, Packet}, State) ->
  process_nfq_packet(Packet, State).

process_nfq_packet({Family, _Version, _Queue, Info},
  #state{socket = Socket, queue = Queue,
    cb = Cb, cb_state = CbState})
  when Family == inet; Family == inet6 ->
  dump_packet(Info),
  {_, Id, _, _} = lists:keyfind(packet_hdr, 1, Info),
  lager:debug("Verdict for ~p~n", [Id]),

  NLA = try Cb:nfq_verdict(Family, Info, CbState) of
          {Verdict, Attrs} when is_list(Attrs) ->
            [{verdict_hdr, Verdict, Id} | Attrs];
          Verdict when is_integer(Verdict) ->
            [{verdict_hdr, Verdict, Id}];
          _ ->
            [{verdict_hdr, ?NF_ACCEPT, Id}]
        catch
          _:_ ->
            [{verdict_hdr, ?NF_ACCEPT, Id}]
        end,
  lager:warning("NLA: ~p", [NLA]),
  Msg = {queue, verdict, [request], 0, 0, {unspec, 0, Queue, NLA}},
  Request = netlink:nl_ct_enc(Msg),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request);

process_nfq_packet({_Family, _Version, _Queue, Info},
  #state{socket = Socket, queue = Queue}) ->
  dump_packet(Info),
  {_, Id, _, _} = lists:keyfind(packet_hdr, 1, Info),
  NLA = [{verdict_hdr, ?NF_ACCEPT, Id}],
  lager:warning("NLA: ~p", [NLA]),
  Msg = {queue, verdict, [request], 0, 0, {unspec, 0, Queue, NLA}},
  Request = netlink:nl_ct_enc(Msg),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request).

dump_packet(PktInfo) ->
  lists:foreach(fun dump_packet_1/1, PktInfo).

dump_packet_1({ifindex_indev, IfIdx}) ->
  lager:debug("InDev: ~w", [IfIdx]);
dump_packet_1({hwaddr, Mac}) ->
  lager:debug("HwAddr: ~s", [flower_tools:format_mac(Mac)]);
dump_packet_1({mark, Mark}) ->
  lager:debug("Mark: ~8.16.0B", [Mark]);
dump_packet_1({payload, Data}) ->
  lager:debug(flower_tools:hexdump(Data));
dump_packet_1(_) ->
  ok.
