%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Nov 2016 7:35 AM
%%%-------------------------------------------------------------------
-module(minuteman_ipvs_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([get_dests/2, add_dest/4, remove_dest/3, add_dest/5, remove_dest/5]).
-export([get_services/1, add_service/3, remove_service/2, remove_service/3]).
-export([service_address/1, destination_address/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    netlink_generic :: pid(),
    family
}).
-type state() :: #state{}.
-include_lib("gen_netlink/include/netlink.hrl").

-define(IP_VS_CONN_F_FWD_MASK, 16#7).       %%  mask for the fwd methods
-define(IP_VS_CONN_F_MASQ, 16#0).           %%  masquerading/NAT
-define(IP_VS_CONN_F_LOCALNODE, 16#1).      %%  local node
-define(IP_VS_CONN_F_TUNNEL, 16#2).         %%  tunneling
-define(IP_VS_CONN_F_DROUTE, 16#3).         %%  direct routing
-define(IP_VS_CONN_F_BYPASS, 16#4).         %%  cache bypass
-define(IP_VS_CONN_F_SYNC, 16#20).          %%  entry created by sync
-define(IP_VS_CONN_F_HASHED, 16#40).        %%  hashed entry
-define(IP_VS_CONN_F_NOOUTPUT, 16#80).      %%  no output packets
-define(IP_VS_CONN_F_INACTIVE, 16#100).     %%  not established
-define(IP_VS_CONN_F_OUT_SEQ, 16#200).      %%  must do output seq adjust
-define(IP_VS_CONN_F_IN_SEQ, 16#400).       %%  must do input seq adjust
-define(IP_VS_CONN_F_SEQ_MASK, 16#600).     %%  in/out sequence mask
-define(IP_VS_CONN_F_NO_CPORT, 16#800).     %%  no client port set yet
-define(IP_VS_CONN_F_TEMPLATE, 16#1000).    %%  template, not connection
-define(IP_VS_CONN_F_ONE_PACKET, 16#2000).  %%  forward only one packet

-define(IP_VS_SVC_F_PERSISTENT, 16#1).          %% persistent port */
-define(IP_VS_SVC_F_HASHED,     16#2).          %% hashed entry */
-define(IP_VS_SVC_F_ONEPACKET,  16#4).          %% one-packet scheduling */
-define(IP_VS_SVC_F_SCHED1,     16#8).          %% scheduler flag 1 */
-define(IP_VS_SVC_F_SCHED2,     16#10).          %% scheduler flag 2 */
-define(IP_VS_SVC_F_SCHED3,     16#20).          %% scheduler flag 3 */

-type service() :: term().
-type dest() :: term().
-export_type([service/0, dest/0]).

%%%===================================================================
%%% API
%%%===================================================================

-spec(get_services(Pid :: pid()) -> [service()]).
get_services(Pid) ->
    gen_server:call(Pid, get_services).

-spec(add_service(Pid :: pid(), IP :: inet:ip4_address(), Port :: inet:port_number()) -> ok).
add_service(Pid, IP, Port) ->
    gen_server:call(Pid, {add_service, IP, Port}).

-spec(remove_service(Pid :: pid(), Service :: service()) -> ok).
remove_service(Pid, Service) ->
    gen_server:call(Pid, {remove_service, Service}).

-spec(remove_service(Pid :: pid(), IP :: inet:ip4_address(), Port :: inet:port_number()) -> ok).
remove_service(Pid, IP, Port) ->
    gen_server:call(Pid, {remove_service, IP, Port}).

-spec(get_dests(Pid :: pid(), Service :: service()) -> [dest()]).
get_dests(Pid, Service) ->
    gen_server:call(Pid, {get_dests, Service}).

-spec(remove_dest(Pid :: pid(), ServiceIP :: inet:ip4_address(), ServicePort :: inet:port_number(),
    DestIP :: inet:ip4_address(), DestPort :: inet:port_number()) -> ok | error).
remove_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort) ->
    gen_server:call(Pid, {remove_dest, ServiceIP, ServicePort, DestIP, DestPort}).

-spec(remove_dest(Pid :: pid(), Service :: service(), Dest :: dest()) -> ok | error).
remove_dest(Pid, Service, Dest) ->
    gen_server:call(Pid, {remove_dest, Service, Dest}).


-spec(add_dest(Pid :: pid(), Service :: service(), IP :: inet:ip4_address(), Port :: inet:port_number()) -> ok | error).
add_dest(Pid, Service, IP, Port) ->
    gen_server:call(Pid, {add_dest, Service, IP, Port}).


-spec(add_dest(Pid :: pid(), ServiceIP :: inet:ip4_address(), ServicePort :: inet:port_number(),
    DestIP :: inet:ip4_address(), DestPort :: inet:port_number()) -> ok | error).
add_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort) ->
    gen_server:call(Pid, {add_dest, ServiceIP, ServicePort, DestIP, DestPort}).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

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
    {ok, Pid} = minuteman_netlink:start_link(),
    {ok, Family} = minuteman_netlink:get_family(Pid, "IPVS"),
    {ok, #state{netlink_generic = Pid, family = Family}}.

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

handle_call(get_services, _From, State) ->
    Reply = handle_get_services(State),
    {reply, Reply, State};
handle_call({add_service, IP, Port}, _From, State) ->
    Reply = handle_add_service(IP, Port, State),
    {reply, Reply, State};
handle_call({remove_service, Service}, _From, State) ->
    Reply = handle_remove_service(Service, State),
    {reply, Reply, State};
handle_call({remove_service, IP, Port}, _From, State) ->
    Reply = handle_remove_service(IP, Port, State),
    {reply, Reply, State};
handle_call({get_dests, Service}, _From, State) ->
    Reply = handle_get_dests(Service, State),
    {reply, Reply, State};
handle_call({add_dest, Service, IP, Port}, _From, State) ->
    Reply = handle_add_dest(Service, IP, Port, State),
    {reply, Reply, State};
handle_call({add_dest, ServiceIP, ServicePort, DestIP, DestPort}, _From, State) ->
    Reply = handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, State),
    {reply, Reply, State};
handle_call({remove_dest, ServiceIP, ServicePort, DestIP, DestPort}, _From, State) ->
    Reply = handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, State),
    {reply, Reply, State};
handle_call({remove_dest, Service, Dest}, _From, State) ->
    Reply = handle_remove_dest(Service, Dest, State),
    {reply, Reply, State}.

-spec(service_address(service()) -> {protocol(), inet:ip4_address(), inet:port_number()}).
service_address(Service) ->
    AF = proplists:get_value(address_family, Service),
    Protocol = netlink_codec:protocol_to_atom(proplists:get_value(protocol, Service)),
    AddressBin = proplists:get_value(address, Service),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Service),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {Protocol, InetAddr, Port}
    end.

-spec(destination_address(Destination :: dest()) -> {inet:ip4_address(), inet:port_number()}).
destination_address(Destination) ->
    AF = proplists:get_value(address_family, Destination),
    AddressBin = proplists:get_value(address, Destination),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Destination),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {InetAddr, Port}
    end.

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
handle_get_services(#state{netlink_generic = Pid, family = Family}) ->
    AF = netlink_codec:family_to_int(inet),
    Protocol = netlink_codec:protocol_to_int(tcp),
    Message =
        #get_service{request = [
            {service, [
                {address_family, AF},
                {protocol, Protocol}
            ]}
        ]},
    {ok, Replies} = minuteman_netlink:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(service, MaybeService) || #netlink{msg = #new_service{request = MaybeService}} <- Replies,
        proplists:is_defined(service, MaybeService)].

handle_remove_service(IP, Port, State) ->
    Protocol = netlink_codec:protocol_to_int(tcp),
    Service = ip_to_address(IP) ++ [{port, Port}, {protocol, Protocol}],
    handle_remove_service(Service, State).

handle_remove_service(Service, #state{netlink_generic = Pid, family = Family}) ->
    case minuteman_netlink:request(Pid, Family, ipvs, [], #del_service{request = [{service, Service}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

handle_add_service(IP, Port, #state{netlink_generic = Pid, family = Family}) ->
    Flags = 0,
    Service0 = [
        {protocol, netlink_codec:protocol_to_int(tcp)},
        {port, Port},
        {sched_name, "wlc"},
        {netmask, 16#ffffffff},
        {flags, Flags, 16#ffffffff},
        {timeout, 0}
    ],
    Service1 = ip_to_address(IP) ++ Service0,
    lager:info("Adding Service: ~p", [Service1]),
    case minuteman_netlink:request(Pid, Family, ipvs, [], #new_service{request = [{service, Service1}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

handle_get_dests(Service, #state{netlink_generic = Pid, family = Family}) ->
    Message = #get_dest{request = [{service, Service}]},
    {ok, Replies} = minuteman_netlink:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(dest, MaybeDest) || #netlink{msg = #new_dest{request = MaybeDest}} <- Replies,
        proplists:is_defined(dest, MaybeDest)].

handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, State) ->
    Protocol = netlink_codec:protocol_to_int(tcp),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol}],
    handle_add_dest(Service, DestIP, DestPort, State).

handle_add_dest(Service, IP, Port, #state{netlink_generic = Pid, family = Family}) ->
    Base = [{fwd_method, ?IP_VS_CONN_F_MASQ}, {weight, 1}, {u_threshold, 0}, {l_threshold, 0}],
    Dest = [{port, Port}] ++ Base ++ ip_to_address(IP),
    lager:info("Adding backend ~p to service ~p~n", [{IP, Port}, Service]),
    Msg = #new_dest{request = [{dest, Dest}, {service, Service}]},
    case minuteman_netlink:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, State) ->
    Protocol = netlink_codec:protocol_to_int(tcp),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol}],
    Dest = ip_to_address(DestIP) ++ [{port, DestPort}],
    handle_remove_dest(Service, Dest, State).

handle_remove_dest(Service, Dest, #state{netlink_generic = Pid, family = Family}) ->
    lager:info("Deleting Dest: ~p~n", [Dest]),
    Msg = #del_dest{request = [{dest, Dest}, {service, Service}]},
    case minuteman_netlink:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

ip_to_address(IP0) when size(IP0) == 4 ->
    [{address_family, netlink_codec:family_to_int(inet)}, {address, ip_to_address2(IP0)}];
ip_to_address(IP0) when size(IP0) == 16 ->
    [{address_family, netlink_codec:family_to_int(inet6)}, {address, ip_to_address2(IP0)}].

ip_to_address2(IP0) ->
    IP1 = tuple_to_list(IP0),
    IP2 = binary:list_to_bin(IP1),
    Padding = 8 * (16 - size(IP2)),
    <<IP2/binary, 0:Padding/integer>>.

