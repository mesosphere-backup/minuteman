%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. May 2016 5:06 PM
%%%-------------------------------------------------------------------
-module(minuteman_lashup_vip_listener).
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
-define(RPC_TIMEOUT, 1000).
-define(RPC_RETRY_TIME, 15000).
-define(ZONE_NAMES, [
    [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    [<<"l4lb">>, <<"thisdcos">>, <<"global">>],
    [<<"dclb">>, <<"thisdcos">>, <<"directory">>],
    [<<"dclb">>, <<"thisdcos">>, <<"global">>]
]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("minuteman.hrl").
-include_lib("mesos_state/include/mesos_state.hrl").
-include_lib("dns/include/dns.hrl").


-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
    ref = erlang:error() :: reference(),
    allocated_ip_ports = gb_sets:empty() :: gb_sets:set(port_ip()),
    name_to_ip_port = gb_trees:empty() :: gb_trees:tree(named_vip(), inet:ip4_address())

}).
-type vip_name() :: binary().
-type named_vip() :: {{vip_name(), framework_name()}, inet:port_number()}.
-type state() :: #state{}.
-type port_ip() :: {inet:port_number(), inet:ip4_address()}.


-define(MIN_IP, {11, 0, 0, 0}).
-define(MIN_INT_IP, 16#0b000000).
-ifdef(TEST).
-define(MAX_IP, {11, 0, 0, 254}).
-define(MAX_INT_IP, 16#0b0000fe).
-else.
-define(MAX_IP, {11, 255, 255, 254}).
-define(MAX_INT_IP, 16#0bfffffe).
-endif.


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
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?VIPS_KEY}) -> true end)),
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
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State0 = #state{ref = Ref}) when Ref == Reference ->
    State1 = handle_event(Event, State0),
    {noreply, State1};
handle_info(retry_spartan, State) ->
    retry_spartan(State),
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

handle_event(_Event = #{value := VIPs0}, State0) ->
    VIPs1 = lists:map(fun rewrite_keys/1, VIPs0),
    {Vips2, State1} = process_vips(VIPs1, State0),
    push_state_to_spartan(State1),
    minuteman_vip_events:push_vips(Vips2),
    State1.

retry_spartan(State) ->
    push_state_to_spartan(State).

push_state_to_spartan(State) ->
    ZoneNames = ?ZONE_NAMES,
    Zones = lists:map(fun(ZoneName) -> zone(ZoneName, State) end, ZoneNames),
    push_zones(Zones).

push_zones([]) ->
    ok;
push_zones([Zone|Zones]) ->
    case push_zone(Zone) of
        ok ->
            push_zones(Zones);
        {error, Reason} ->
            timer:send_after(?RPC_RETRY_TIME, retry_spartan),
            lager:warning("Aborting pushing zones to Spartan: ~p", [Reason]),
            error
    end.

%% TODO(sargun): Based on the response to https://github.com/aetrion/erl-dns/issues/46 -- we might have to handle
%% returns from rpc which are errors
push_zone(Zone) ->
    case rpc:call(spartan_name(), erldns_zone_cache, put_zone, [Zone], ?RPC_TIMEOUT) of
        Reason = {badrpc, _} ->
            {error, Reason};
        ok ->
            ok
    end.

spartan_name() ->
    [_Node, Host] = binary:split(atom_to_binary(node(), utf8), <<"@">>),
    SpartanBinName = <<"spartan@", Host/binary>>,
    binary_to_atom(SpartanBinName, utf8).

-spec(zone([binary()], state()) -> {Name :: binary(), Sha :: binary(), [#dns_rr{}]}).
zone(ZoneComponents, State) ->
    Now = timeish(),
    zone(Now, ZoneComponents, State).

-spec(timeish() -> 0..4294967295).
timeish() ->
    case erlang:system_time(seconds) of
        Time when Time < 0 ->
            0;
        Time when Time > 4294967295 ->
            4294967295;
        Time ->
            Time
    end.


-spec(zone(Now :: 0..4294967295, [binary()], state()) -> {Name :: binary(), Sha :: binary(), [#dns_rr{}]}).
zone(Now, ZoneComponents, _State = #state{name_to_ip_port = NameIPPort}) ->
    ZoneName = binary_to_name(ZoneComponents),
    Records0 = [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 3600,
            data = #dns_rrdata_soa{
                mname = binary_to_name([<<"ns">>|ZoneComponents]), %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = Now, %% Hopefully there is not more than 1 update/sec :)
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = binary_to_name(ZoneComponents),
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = binary_to_name([<<"ns">>|ZoneComponents])
            }
        },
        #dns_rr{
            name = binary_to_name([<<"ns">>|ZoneComponents]),
            type = ?DNS_TYPE_A,
            ttl = 3600,
            data = #dns_rrdata_a{
                ip = {198, 51, 100, 1} %% Default Spartan IP
            }
        }
    ],
    {_, Records1} = gb_tree_fold(fun add_records_fold/3, {ZoneComponents, Records0}, NameIPPort),
    Sha = crypto:hash(sha, term_to_binary(Records1)),
    {ZoneName, Sha, Records1}.

add_records_fold({{VIPName, FrameworkName}, _Port}, IP, {ZoneComponents, Records0}) ->
    Record = #dns_rr{
        name = binary_to_name([VIPName, FrameworkName] ++ ZoneComponents),
        type = ?DNS_TYPE_A,
        ttl = 5,
        data = #dns_rrdata_a{
            ip = IP
        }
    },
    {ZoneComponents, [Record|Records0]}.

gb_tree_fold(FoldFun, Acc0, Tree) ->
    Iterator = gb_trees:iterator(Tree),
    do_gb_tree_fold(FoldFun, Acc0, Iterator).

do_gb_tree_fold(FoldFun, Acc0, Iterator0) ->
    case gb_trees:next(Iterator0) of
        none ->
            Acc0;
        {Key, Value, Iterator1} ->
            Acc1 = FoldFun(Key, Value, Acc0),
            do_gb_tree_fold(FoldFun, Acc1, Iterator1)
    end.

-spec(binary_to_name([binary()]) -> binary()).
binary_to_name(Binaries0) ->
    Binaries1 = lists:map(fun mesos_state:domain_frag/1, Binaries0),
    binary_join(Binaries1, <<".">>).

-spec(binary_join([binary()], Sep :: binary()) -> binary()).
binary_join(Binaries, Sep) ->
    lists:foldr(
        fun
            %% This short-circuits the first run
            (Binary, <<>>) ->
                Binary;
            (<<>>, Acc) ->
                Acc;
            (Binary, Acc) ->
                <<Binary/binary, Sep/binary, Acc/binary>>
        end,
        <<>>,
        Binaries
    ).

process_vips(VIPs0, State0) ->
    State1 = discard_old_names(VIPs0, State0),
    {VIPs1, State2} =
        lists:foldl(
            fun remap_name_and_allocate/2,
            {[], State1},
            VIPs0
        ),
    VIPs2 = lists:usort(VIPs1),
    {VIPs2, State2}.


allocate_vip(Key, NameIPPort0, AllocIPPorts0) ->
    RangeSize = ?MAX_INT_IP - ?MIN_INT_IP,
    StartSearch = erlang:phash2(Key, RangeSize),

    allocate_vip(Key, NameIPPort0, AllocIPPorts0, StartSearch, StartSearch + 1, RangeSize).


allocate_vip(_, _, _, StartSearch, CurrentOffset, RangeSize) when CurrentOffset rem RangeSize == StartSearch  ->
    erlang:throw(out_of_ips);
allocate_vip(VIP = {_VIPKey, PortNumber}, NameIPPort0, AllocIPPorts0, StartSearch, CurrentOffset, RangeSize) ->
    TryIP = integer_to_ip(?MIN_INT_IP + (CurrentOffset rem RangeSize)),
    TestIPPort = {PortNumber, TryIP},
    Iterator = gb_sets:iterator_from(TestIPPort, AllocIPPorts0),
    case gb_sets:next(Iterator) of
        {TestIPPort, _} ->
            allocate_vip(VIP, NameIPPort0, AllocIPPorts0, StartSearch, CurrentOffset + 1, RangeSize);
        _ ->
            AllocIPPorts1 = gb_sets:add(TestIPPort, AllocIPPorts0),
            NameIPPort1 = gb_trees:insert(VIP, TryIP, NameIPPort0),
            {TestIPPort, NameIPPort1, AllocIPPorts1}
    end.

remap_name_and_allocate({{Protocol, {name, {VIPName, FrameworkName}}, PortNumber}, Backends},
        {Acc, State0 = #state{name_to_ip_port = NameIPPort0, allocated_ip_ports = AllocIPPorts0}}) ->
    Key = {{VIPName, FrameworkName}, PortNumber},
    case gb_trees:lookup(Key, NameIPPort0) of
        none ->
            {{Port, IP}, NameIPPort1, AllocIPPorts1} = allocate_vip(Key, NameIPPort0, AllocIPPorts0),
            State1 = State0#state{name_to_ip_port = NameIPPort1, allocated_ip_ports = AllocIPPorts1},
            VIP = {{Protocol, IP, Port}, Backends},
            {[VIP|Acc], State1};
        {value, IP} ->
            VIP = {{Protocol, IP, PortNumber}, Backends},
            {[VIP|Acc], State0}
    end;
remap_name_and_allocate(VIP, {Acc, State}) ->
    {[VIP|Acc], State}.
discard_old_names(VIPs, State = #state{name_to_ip_port = NameIPPort0, allocated_ip_ports = AllocIPPorts0}) ->
    OldNames = old_names(VIPs, State),
    OldIPPorts = lists:map(
        fun(Key = {_, Port}) ->
            IP = gb_trees:get(Key, NameIPPort0),
            {Port, IP}
        end,
        OldNames),
    NameIPPort1 =
        lists:foldl(
            fun gb_trees:delete/2,
            NameIPPort0,
            OldNames
        ),
    AllocIPPorts1 =
        lists:foldl(
            fun gb_sets:delete/2,
            AllocIPPorts0,
            OldIPPorts
        ),
    State#state{name_to_ip_port = NameIPPort1, allocated_ip_ports = AllocIPPorts1}.

old_names(VIPs, _State = #state{name_to_ip_port = NamedIPPort}) ->
    NamedVIPs = [VIP || VIP = {{_Protocol, {name, {_VIPName, _FrameworkName}}, _PortNumber}, _Backends} <- VIPs],
    NamedVIPTreeKeys = [{{VIPName, FrameworkName}, PortNumber} ||
        {{_Protocol, {name, {VIPName, FrameworkName}}, PortNumber}, _Backends} <- NamedVIPs],
    % Returns the keys in Tree as an ordered list.
    CurrentVIPs = gb_trees:keys(NamedIPPort),
    ordsets:subtract(CurrentVIPs, ordsets:from_list(NamedVIPTreeKeys)).

rewrite_keys({{RealKey, riak_dt_orswot}, Value}) ->
    {RealKey, Value}.

-spec(integer_to_ip(IntIP :: 0..4294967295) -> inet:ip4_address()).
integer_to_ip(IntIP) ->
    <<A, B, C, D>> = <<IntIP:32/integer>>,
    {A, B, C, D}.


-ifdef(TEST).
-define(FAKE_BACKENDS, [backend1, backend2]).

-spec(ip_to_integer(inet:ip4_address()) -> 0..4294967295).
ip_to_integer(_IP = {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP.

simple_allocate1_test() ->
    State0 = #state{ref = undefined},
    {Out, _State1} = remap_name_and_allocate({{tcp, {name, {<<"foo">>, <<"marathon">>}}, 5000}, ?FAKE_BACKENDS},
        {[], State0}),
    ?assertEqual([{{tcp, {11, 0, 0, 106}, 5000}, ?FAKE_BACKENDS}], Out).


simple_allocate2_test() ->
    ExpectedRemap = [{{tcp, {11, 0, 0, 106}, 5000}, ?FAKE_BACKENDS}],
    State0 = #state{ref = undefined},
    {Out, State1} = remap_name_and_allocate({{tcp, {name, {<<"foo">>, <<"marathon">>}}, 5000}, ?FAKE_BACKENDS},
        {[], State0}),
    ?assertEqual(ExpectedRemap, Out),
    {Out, State1} = remap_name_and_allocate({{tcp, {name, {<<"foo">>, <<"marathon">>}}, 5000}, ?FAKE_BACKENDS},
        {[], State1}).

simple_allocate3_test() ->
    State0 = #state{ref = undefined},
    %                        {_, S1} = process_vips(VIPs1, S0),
    FakeVIP1 = {{tcp, {name, {<<"foo1">>, <<"marathon">>}}, 5000}, [foo1]},
    FakeVIP2 = {{tcp, {name, {<<"foo2">>, <<"marathon">>}}, 5000}, [foo2]},
    FakeVIP3 = {{tcp, {name, {<<"foo3">>, <<"marathon">>}}, 5000}, [foo3]},
    FakeVIP4 = {{tcp, {name, {<<"foo4">>, <<"marathon">>}}, 5001}, [foo4]},
    {V0, State1} = process_vips([FakeVIP1, FakeVIP2, FakeVIP3, FakeVIP4], State0),
    {V1, State2} = process_vips([FakeVIP1, FakeVIP3, FakeVIP4], State1),
    {V0, State3} = process_vips([FakeVIP1, FakeVIP2, FakeVIP3, FakeVIP4], State2),
    ?assertEqual([], V1 -- V0),
    State3.

zone_test() ->
    State = simple_allocate3_test(),
    Components = [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    Zone = zone(1463878088, Components, State),

    Expected = {<<"l4lb.thisdcos.directory">>,
        <<146, 243, 41, 235, 14, 114, 224, 170, 243, 14, 90, 250, 173, 146, 23, 42,
            254, 111, 132, 248>>, %% SHA1 hash of zone
        [#dns_rr{name = <<"foo4.marathon.l4lb.thisdcos.directory">>, class = 1,
            type = 1, ttl = 5,
            data = #dns_rrdata_a{ip = {11, 0, 0, 86}}},
            #dns_rr{name = <<"foo3.marathon.l4lb.thisdcos.directory">>, class = 1,
                type = 1, ttl = 5,
                data = #dns_rrdata_a{ip = {11, 0, 0, 0}}},
            #dns_rr{name = <<"foo2.marathon.l4lb.thisdcos.directory">>, class = 1,
                type = 1, ttl = 5,
                data = #dns_rrdata_a{ip = {11, 0, 0, 108}}},
            #dns_rr{name = <<"foo1.marathon.l4lb.thisdcos.directory">>, class = 1,
                type = 1, ttl = 5,
                data = #dns_rrdata_a{ip = {11, 0, 0, 36}}},
            #dns_rr{name = <<"l4lb.thisdcos.directory">>, class = 1, type = 6, ttl = 3600,
                data = #dns_rrdata_soa{mname = <<"ns.l4lb.thisdcos.directory">>,
                    rname = <<"support.mesosphere.com">>,
                    serial = 1463878088, refresh = 60, retry = 180,
                    expire = 86400, minimum = 1}},
            #dns_rr{name = <<"l4lb.thisdcos.directory">>, class = 1, type = 2, ttl = 3600,
                data = #dns_rrdata_ns{dname = <<"ns.l4lb.thisdcos.directory">>}},
            #dns_rr{name = <<"ns.l4lb.thisdcos.directory">>, class = 1, type = 1,
                ttl = 3600,
                data = #dns_rrdata_a{ip = {198, 51, 100, 1}}}
        ]},
    ?assertEqual(Expected, Zone).





overallocate_test() ->
    State0 = #state{ref = undefined},
    FakeVIPs = [{{tcp, {name, {<<"foo1:", N/integer>>, <<"marathon">>}}, 5000},
        [{backend, N}]} || N <- lists:seq(1, ?MAX_INT_IP - ?MIN_INT_IP + 100)],
    ?assertThrow(out_of_ips, process_vips(FakeVIPs, State0)).

create_delete_test() ->
    State0 = #state{ref = undefined},
    {_Out, State1} = remap_name_and_allocate({{tcp, {name, {<<"foo">>, <<"marathon">>}}, 5000}, ?FAKE_BACKENDS},
        {[], State0}),
    {[], State2} = process_vips([], State1),
    ?assertEqual(0, gb_sets:size(State2#state.allocated_ip_ports)),
    ?assertEqual(0, gb_trees:size(State2#state.name_to_ip_port)).

ip_to_integer_test() ->
    ?assertEqual(4278190080, ip_to_integer({255, 0, 0, 0})),
    ?assertEqual(0, ip_to_integer({0, 0, 0, 0})),
    ?assertEqual(16711680, ip_to_integer({0, 255, 0, 0})),
    ?assertEqual(65535, ip_to_integer({0, 0, 255, 255})),
    ?assertEqual(16909060, ip_to_integer({1, 2, 3, 4})).

integer_to_ip_test() ->
    ?assertEqual({255, 0, 0, 0}, integer_to_ip(4278190080)),
    ?assertEqual({0, 0, 0, 0}, integer_to_ip(0)),
    ?assertEqual({0, 255, 0, 0}, integer_to_ip(16711680)),
    ?assertEqual({0, 0, 255, 255}, integer_to_ip(65535)),
    ?assertEqual({1, 2, 3, 4}, integer_to_ip(16909060)).


all_prop_test_() ->
    {timeout, 60, [fun() -> [] = proper:module(?MODULE, [{to_file, user}, {numtests, 100}]) end]}.


ip() ->
    {byte(), byte(), byte(), byte()}.
int_ip() ->
    integer(0, 4294967295).

valid_int_ip_range(Int) when Int >= 0 andalso Int =< 4294967295 ->
    true;
valid_int_ip_range(_) ->
    false.

prop_integer_to_ip() ->
    ?FORALL(
        IP,
        ip(),
        valid_int_ip_range(ip_to_integer(IP))
    ).

prop_integer_and_back() ->
    ?FORALL(
        IP,
        ip(),
        integer_to_ip(ip_to_integer(IP)) =:= IP
    ).

prop_ip_and_back() ->
    ?FORALL(
        IntIP,
        int_ip(),
        ip_to_integer(integer_to_ip(IntIP)) =:= IntIP
    ).

backends() ->
    orderedlist({ip(), port()}).

port() ->
    integer(0, 65535).
normal_vip() ->
    {
        {tcp, ip(), port()},
        backends()
    }.
framework_name() ->
    binary().
vip_name() ->
    binary().
named_vip() ->
    {
        {tcp, {name, vip_name(), framework_name()}, port()},
        backends()
    }.
named_or_normal_vip() ->
    oneof([named_vip(), normal_vip()]).

vips() ->
    orderedlist(named_or_normal_vip()).

prop_never_lose_vip() ->
    State0 = #state{ref = undefined},
    ?FORALL(
        VIPs0,
        vips(),
        begin
            VIPs1 = lists:usort(VIPs0),
            {VIPs2, _State1} = process_vips(VIPs1, State0),
            length(VIPs2) =:= length(VIPs1)
        end
    ).

prop_dont_crash() ->
    State0 = #state{ref = undefined},
    ?FORALL(
        ListOfVIPs0,
        list(vips()),
        begin
                lists:foldl(
                    fun(VIPs0, S0) ->
                        VIPs1 = orddict:from_list(VIPs0),
                        NamedVIPs = [x || {{_Protocol, {name, _Name}, _PortNumber}, _Backends} <- VIPs1],
                        NamedVIPCount = length(NamedVIPs),
                        {_, S1} = process_vips(VIPs1, S0),
                        true = gb_trees:size(S1#state.name_to_ip_port) =:= NamedVIPCount,
                        true = gb_sets:size(S1#state.allocated_ip_ports) =:= NamedVIPCount,
                        S1
                    end,
                    State0,
                    ListOfVIPs0
                ),
            true
        end
    ).

-endif.