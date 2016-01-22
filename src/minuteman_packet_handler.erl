%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:36 AM
%%%-------------------------------------------------------------------
-module(minuteman_packet_handler).
-author("sdhillon").
-author("Tyler Neely").

%% API
-export([handle/2, start_link/1, do_handle/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("pkt/include/pkt.hrl").
-include_lib("kernel/include/inet.hrl").
-include("minuteman.hrl").

%%%===================================================================
%%% API
%%%===================================================================
handle(NFQPid, Info) ->
  ChildSpec = #{
    id => make_ref(),
    start => {?MODULE, start_link, [[NFQPid, Info]]},
    restart => temporary
  },
  supervisor:start_child(minuteman_worker_sup, ChildSpec).

start_link(Args) ->
  FullSweep = 65535 * 1000,
  HeapSize = 1000000,
  Opts = [link, {priority, high}, {fullsweep_after, FullSweep}, {min_heap_size, HeapSize}],
  %% Basically never full sweep, because the process dies pretty quickly
  Pid = proc_lib:spawn_opt(?MODULE, do_handle, Args, Opts),
  {ok, Pid}.

do_handle(NFQPid, Info) ->
  initialize_seed(),
  {payload, Payload} = lists:keyfind(payload, 1, Info),
  case to_mapping(Payload) of
    {ok, Mapping} ->
      lager:debug("Mapping: ~p", [Mapping]),
      minuteman_ct:install_mapping(Mapping);
    Else ->
      lager:error("Unable to handle mapping: ~p", [Else])
  end,
  gen_server:cast(NFQPid, {accept_packet, Info}).


get_src_addr(SrcAddr, BackendIP) ->
  case {minuteman_iface_server:is_local(SrcAddr), minuteman_iface_server:is_local(BackendIP)} of
    {true, true} ->
      {127, 0, 0, 1};
    {false, true} ->
      SrcAddr;
    {_, false} ->
      {ok, Route} = minuteman_routes:get_route(BackendIP),
      %% TODO: Add validation here
      %% TODO: Fallback to another IP
      PrefSrc = proplists:get_value(prefsrc, Route),
      PrefSrc
  end.


to_mapping(Payload) ->
  [IP, TCP|_] = pkt:decapsulate(ipv4, Payload),
  DstAddr = IP#ipv4.daddr,
  DstPort = TCP#tcp.dport,
  case minuteman_vip_server:get_backend(DstAddr, DstPort) of
    {ok, _Backend = {BackendIP, BackendPort}} ->
      SrcAddr = IP#ipv4.saddr,
      SrcPort = TCP#tcp.sport,
      NewSrcAddr = get_src_addr(SrcAddr, BackendIP),
      Mapping = #mapping{orig_src_ip = SrcAddr,
        orig_src_port = SrcPort,
        orig_dst_ip = DstAddr,
        orig_dst_port = DstPort,
        new_src_ip = NewSrcAddr,
        new_dst_ip = BackendIP,
        new_dst_port = BackendPort},
      {ok, Mapping};

    Else ->
      lager:warning("Could not map connection"),
      {error, {no_backend, Else}}
  end.



initialize_seed() ->
  random:seed(erlang:phash2([node()]),
    erlang:monotonic_time(),
    erlang:unique_integer()).

-compile(export_all).
-ifdef(TEST).

%% TODO (local_to_local) test
%% TODO (foreign_to_local) test
is_local({127, 0, 0, 1}) ->
  true;
is_local(_) ->
  false.

local_to_foreign() ->

  meck:new(minuteman_iface_server),
  meck:expect(minuteman_iface_server, is_local, fun is_local/1),
  meck:new(minuteman_vip_server),
  meck:expect(minuteman_vip_server, get_backend, fun({1, 1, 1, 1}, 1000) -> {ok, {{8, 8, 8, 8}, 31421}} end),
  meck:new(minuteman_routes),
  meck:expect(minuteman_routes, get_route, fun({8, 8, 8, 8}) -> {ok, [{prefsrc, {9, 9, 9, 9}}]} end),

  Payload = <<>>,
  TCP = #tcp{sport = 55000, dport = 1000},
  IPv4 = #ipv4{daddr = {1, 1, 1, 1}},
  Packet = <<(pkt:ipv4(IPv4))/binary, (pkt:tcp(TCP))/binary, Payload/binary>>,
  ?debugFmt("Packet: ~p~n", [ Packet]),

  ExpectedMapping = #mapping{
    orig_src_ip = {127, 0, 0, 1},
    orig_src_port = 55000,
    orig_dst_ip = {1, 1, 1, 1},
    orig_dst_port = 1000,
    new_src_ip = {9, 9, 9, 9},
    new_dst_ip = {8, 8, 8, 8},
    new_dst_port = 31421},
  ?assertEqual({ok, ExpectedMapping}, to_mapping(Packet)),
  meck:unload().

foreign_to_foreign_test() ->
  Payload = <<>>,
  TCP = #tcp{sport = 55000, dport = 1000},
  IPv4 = #ipv4{saddr = {8, 8, 4, 4}, daddr = {1, 1, 1, 1}},
  Packet = <<(pkt:ipv4(IPv4))/binary, (pkt:tcp(TCP))/binary, Payload/binary>>,

  meck:new(minuteman_iface_server),
  meck:expect(minuteman_iface_server, is_local, fun is_local/1),
  meck:new(minuteman_vip_server),
  meck:expect(minuteman_vip_server, get_backend, fun({1, 1, 1, 1}, 1000) -> {ok, {{8, 8, 8, 8}, 31421}} end),
  meck:new(minuteman_routes),
  meck:expect(minuteman_routes, get_route, fun({8, 8, 8, 8}) -> {ok, [{prefsrc, {9, 9, 9, 9}}]} end),
  ExpectedMapping = #mapping{
    orig_src_ip = {8, 8, 4, 4},
    orig_src_port = 55000,
    orig_dst_ip = {1, 1, 1, 1},
    orig_dst_port = 1000,
    new_src_ip = {9, 9, 9, 9},
    new_dst_ip = {8, 8, 8, 8},
    new_dst_port = 31421},
  ?assertEqual({ok, ExpectedMapping}, to_mapping(Packet)),
  meck:unload().
-endif.
