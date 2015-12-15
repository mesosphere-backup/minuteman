%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:36 AM
%%%-------------------------------------------------------------------
-module(minuteman_packet_handler).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, handle/1, refresh_ifaddrs/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("pkt/include/pkt.hrl").

-include_lib("kernel/include/inet.hrl").

-include("enfhackery.hrl").
-define(SERVER, ?MODULE).

-define(REFRESH_INTERVAL, 5000).
-record(state, {local_addrs = erlang:error()}).

%%%===================================================================
%%% API
%%%===================================================================


refresh_ifaddrs(Pid) ->
  {ok, InetIfaddrs} = inet:getifaddrs(),
  InetIfaddrsSet = inet_ifaddrs_to_set(InetIfaddrs),
  gen_server:cast(Pid, {refresh_ifaddrs, InetIfaddrsSet}).

handle(Payload) ->
  catch gen_server:call(?SERVER, {handle_payload, Payload}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
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
  {ok, InetIfaddrs} = inet:getifaddrs(),
  InetIfaddrsSet = inet_ifaddrs_to_set(InetIfaddrs),
  {ok, _Tref} = timer:apply_interval(?REFRESH_INTERVAL, ?MODULE, refresh_ifaddrs, [self()]),
  {ok, #state{local_addrs = InetIfaddrsSet}}.

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
handle_call({handle_payload, Payload}, _From, State) ->
  do_handle(Payload, State),
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
handle_cast({refresh_ifaddrs, InetIfaddrs}, State) ->
  {noreply, State#state{local_addrs = InetIfaddrs}};
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

inet_ifaddrs_to_set(IfList) ->
  IfOptsAll = [IfOpts ||{_IfName, IfOpts} <- IfList],
  IfOptsAllFlat = lists:flatten(IfOptsAll),
  AllAddrs = [Addr || {addr, Addr} <- IfOptsAllFlat, tuple_size(Addr) == 4],
  sets:from_list(AllAddrs).

is_local(IP, LocalAddresses) when tuple_size(IP) == 4 ->
  sets:is_element(IP, LocalAddresses).

get_src_addr(SrcAddr, BackendIP, LocalAddresses) ->
  case {is_local(SrcAddr, LocalAddresses), is_local(BackendIP, LocalAddresses)} of
    {true, true} ->
      {127, 0, 0, 1};
    {true, false} ->
      SrcAddr;
    {false, true} ->
      SrcAddr;
    {false, false} ->
      {ok, Route} = minuteman_routes:get_route(BackendIP),
      %% TODO: Add validation here
      %% TODO: Fallback to another IP
      PrefSrc = proplists:get_value(prefsrc, Route),
      PrefSrc
  end.


do_handle(Payload, _State = #state{local_addrs = LocalAddresses}) ->
  case to_mapping(Payload, LocalAddresses) of
    {ok, Mapping} ->
      lager:info("Mapping: ~p", [Mapping]),
      minuteman_ct:handle_mapping(Mapping);
    Else ->
      lager:error("Unable to handle mapping: ~p", [Else])
  end.

to_mapping(Payload, LocalAddresses) ->
  [IP, TCP|_] = pkt:decapsulate(ipv4, Payload),
  DstAddr = IP#ipv4.daddr,
  DstPort = TCP#tcp.dport,
  case minuteman_vip_server:get_backend(DstAddr, DstPort) of
    {ok, Backend = {BackendIP, BackendPort}} ->
      lager:debug("Backend: ~p", [Backend]),
      SrcAddr = IP#ipv4.saddr,
      SrcPort = TCP#tcp.sport,
      NewSrcAddr = get_src_addr(SrcAddr, BackendIP, LocalAddresses),
      Mapping = #mapping{orig_src_ip = SrcAddr,
        orig_src_port = SrcPort,
        orig_dst_ip = DstAddr,
        orig_dst_port = DstPort,
        new_src_ip = NewSrcAddr,
        new_src_port = SrcPort - 31743,
        new_dst_ip = BackendIP,
        new_dst_port = BackendPort},
      {ok, Mapping};

    Else ->
      lager:debug("Could not map connection"),
      {error, {no_backend, Else}}
  end.



-ifdef(TEST).

local_to_foreign_test() ->
  Payload = <<>>,
  TCP = #tcp{sport = 55000, dport = 1000},
  IPv4 = #ipv4{daddr = {1, 1, 1, 1}},
  Packet = <<(pkt:ipv4(IPv4))/binary, (pkt:tcp(TCP))/binary, Payload/binary>>,
  {ok, InetIfaddrs} = inet:getifaddrs(),
  InetIfaddrsSet = inet_ifaddrs_to_set(InetIfaddrs),
  meck:new(minuteman_vip_server),
  meck:expect(minuteman_vip_server, get_backend, fun({1, 1, 1, 1}, 1000) -> {ok, {{8, 8, 8, 8}, 31421}} end),
  ExpectedMapping = #mapping{
    orig_src_ip = {127, 0, 0, 1},
    orig_src_port = 55000,
    orig_dst_ip = {1, 1, 1, 1},
    orig_dst_port = 1000,
    new_src_ip = {127, 0, 0, 1},
    new_src_port = 23257,
    new_dst_ip = {8, 8, 8, 8},
    new_dst_port = 31421},
  ?assertEqual({ok, ExpectedMapping}, to_mapping(Packet, InetIfaddrsSet)),
  meck:unload(minuteman_vip_server).

foreign_to_foreign_test() ->
  Payload = <<>>,
  TCP = #tcp{sport = 55000, dport = 1000},
  IPv4 = #ipv4{saddr = {8, 8, 4, 4}, daddr = {1, 1, 1, 1}},
  Packet = <<(pkt:ipv4(IPv4))/binary, (pkt:tcp(TCP))/binary, Payload/binary>>,
  {ok, InetIfaddrs} = inet:getifaddrs(),
  InetIfaddrsSet = inet_ifaddrs_to_set(InetIfaddrs),
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
    new_src_port = 23257,
    new_dst_ip = {8, 8, 8, 8},
    new_dst_port = 31421},
  ?assertEqual({ok, ExpectedMapping}, to_mapping(Packet, InetIfaddrsSet)),
  meck:unload(minuteman_vip_server),
  meck:unload(minuteman_routes).
-endif.
