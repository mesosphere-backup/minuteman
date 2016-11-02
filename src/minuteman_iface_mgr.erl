%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Nov 2016 7:39 AM
%%%-------------------------------------------------------------------
-module(minuteman_iface_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/1, add_ip/2, remove_ip/2, get_ips/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    netlink_rt      :: pid(),
    if_idx,
    iface_name
}).
-type state() :: #state{}.
-include_lib("gen_netlink/include/netlink.hrl").

%%%===================================================================
%%% API
%%%===================================================================

-spec(add_ip(Pid :: pid(), IP :: inet:ip4_address()) -> ok | error).
add_ip(Pid, IP) ->
    gen_server:call(Pid, {add_ip, IP}).

-spec(remove_ip(Pid :: pid(), IP :: inet:ip4_address()) -> ok | error).
remove_ip(Pid, IP) ->
    gen_server:call(Pid, {remove_ip, IP}).

-spec(get_ips(Pid :: pid()) -> [inet:ip4_address()]).
get_ips(Pid) ->
    gen_server:call(Pid, get_ips).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(InterfaceName :: string()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(InterfaceName) ->
    gen_server:start_link(?MODULE, [InterfaceName], []).

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
init([InterfaceName]) ->
    {ok, Pid} = minuteman_netlink:start_link(?NETLINK_ROUTE),
    State0 = #state{netlink_rt = Pid, iface_name = InterfaceName},
    IfIdx = if_idx(InterfaceName, State0),
    State1 = State0#state{if_idx = IfIdx},
    {ok, State1}.

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

handle_call(get_ips, _From, State) ->
    Reply = handle_get_ips(State),
    {reply, Reply, State};
handle_call({add_ip, IP}, _From, State) ->
    Reply = handle_add_ip(IP, State),
    {reply, Reply, State};
handle_call({remove_ip, IP}, _From, State) ->
    Reply = handle_remove_ip(IP, State),
    {reply, Reply, State}.

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

if_idx(InterfaceName, #state{netlink_rt = Pid}) ->
    Msg = if_idx_msg(InterfaceName),
    {ok, [#rtnetlink{msg = Reply}]} = minuteman_netlink:rtnl_request(Pid, getlink, [], Msg),
    {_Family, _Type, Index, _Flags, _Change, _Req} = Reply,
    Index.

if_idx_msg(InterfaceName) ->
    {
        _Family = packet,
        _Type = arphrd_ether,
        _Index = 0,
        _Flags = [],
        _Change = [],
        _Req = [
            {ifname, InterfaceName},
            {ext_mask, 1}
        ]
    }.

handle_get_ips(#state{iface_name = StateIFaceName}) ->
    {ok, IFaceAddrs} = inet:getifaddrs(),
    [IFaceOpts] = [IfaceOpts || {IFaceName, IfaceOpts} <- IFaceAddrs, string:equal(IFaceName, StateIFaceName)],
    [Addr || {addr, Addr} <- IFaceOpts, size(Addr) == 4].

handle_remove_ip(IP, #state{netlink_rt = Pid, if_idx = Index, iface_name = IFaceName}) ->
    lager:info("Removing IP ~p from interface: ~p", [IP, IFaceName]),
    Req = [{address, IP}, {local, IP}],
    Msg =  {_Family = inet, _PrefixLen = 32, _Flags = 0, _Scope = 0, Index, Req},
    case minuteman_netlink:rtnl_request(Pid, deladdr, [], Msg) of
        {ok, _} ->
            ok;
        Error ->
            lager:error("Failed to remove ip: ~p", [Error]),
            error
    end.

handle_add_ip(IP, #state{netlink_rt = Pid, if_idx = Index, iface_name = IFaceName}) ->
    lager:info("Adding IP ~p to interface: ~p", [IP, IFaceName]),
    Req = [{address, IP}, {local, IP}],
    Msg =  {_Family = inet, _PrefixLen = 32, _Flags = 0, _Scope = 0, Index, Req},
    case minuteman_netlink:rtnl_request(Pid, newaddr, [create, excl], Msg) of
        {ok, _} ->
            ok;
        Error ->
            lager:error("Failed to add ip: ~p", [Error]),
            error
    end.
