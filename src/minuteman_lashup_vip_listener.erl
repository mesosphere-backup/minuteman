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
    lookup_vips/1,
    code_change/3]).

-include_lib("telemetry/include/telemetry.hrl").

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


-type ip4_num() :: 0..16#ffffffff.
-record(state, {
    ref = erlang:error() :: reference(),
    min_ip_num = erlang:error(no_min_ip_num) :: ip4_num(),
    max_ip_num = erlang:error(no_max_ip_num) :: ip4_num()
    }).
-type state() :: #state{}.

-type ip_vip() :: {tcp, inet:ip4_address(), inet:port_number()}.
-type vip_name() :: binary().
-type named_vip() :: {tcp, {name, {vip_name(), framework_name()}}, inet:port_number()}.
-type vip() :: {ip_vip() | named_vip(), [ip_port()]}.




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
    ets_restart(name_to_ip),
    ets_restart(ip_to_name),
    MinIP = ip_to_integer(minuteman_config:min_named_ip()),
    MaxIP = ip_to_integer(minuteman_config:max_named_ip()),
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?VIPS_KEY}) -> true end)),
    State = #state{ref = Ref, max_ip_num = MaxIP, min_ip_num = MinIP},
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
-spec(lookup_vips([{ip, inet:ip4_address()}|{name, binary()}]) ->
                  [{name, binary()}|{ip, inet:ip4_address()}|{badmatch, term()}]).
lookup_vips(Names) ->
    try
        lists:map(fun handle_lookup_vip/1, Names)
    catch
        error:badarg -> []
    end.

handle_lookup_vip({ip, IP}) ->
  ActualIPNum = ip_to_integer(IP),
  case ets:lookup(ip_to_name, ActualIPNum) of
    [{_, IPName}] -> {name, IPName};
    _ -> {badmatch, IP}
  end;
handle_lookup_vip({name, Name}) when is_binary(Name) ->
  case ets:lookup(name_to_ip, Name) of
    [{_, IPNum}] -> {ip, integer_to_ip(IPNum)};
    _ -> {badmatch, Name}
  end;
handle_lookup_vip(Arg)  -> {badmatch, Arg}.

handle_event(_Event = #{value := VIPs}, State) ->
    handle_value(VIPs, State).

handle_value(VIPs0, State) ->
    VIPs1 = process_vips(VIPs0, State),
    push_state_to_spartan(State),
    minuteman_vip_events:push_vips(VIPs1),
    State.

process_vips(VIPs0, State) ->
    VIPs1 = lists:map(fun rewrite_keys/1, VIPs0),
    rebind_names(VIPs1, State).


rewrite_keys({{RealKey, riak_dt_orswot}, Value}) ->
    {RealKey, Value}.

%% @doc Extracts name based vips. Binds names
-spec(rebind_names([vip()], state()) -> [ip_vip()]).
rebind_names(VIPs0, State) ->
    Names0 = [Name || {{tcp, {name, Name}, _Portnumber}, _Backends} <- VIPs0],
    Names1 = lists:map(fun({Name, FWName}) -> binary_to_name([Name, FWName]) end, Names0),
    Names2 = lists:usort(Names1),
    update_name_mapping(Names2, State),
    lists:map(fun(VIP) -> rewrite_name(VIP) end, VIPs0).

-spec(rewrite_name(vip()) -> ip_vip()).
rewrite_name({{tcp, {name, {Name, FWName}}, PortNum}, BEs}) ->
    FullName = binary_to_name([Name, FWName]),
    [{_, IPNum}] = ets:lookup(name_to_ip, FullName),
    IP = integer_to_ip(IPNum),
    {{tcp, IP, PortNum}, BEs};
rewrite_name(Else) ->
    Else.

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
            Time + erlang:unique_integer([positive, monotonic])
    end.

-spec(zone(Now :: 0..4294967295, [binary()], state()) -> {Name :: binary(), Sha :: binary(), [#dns_rr{}]}).
zone(Now, ZoneComponents, _State) ->
    ZoneName = binary_to_name(ZoneComponents),
    Records0 = [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 5,
            data = #dns_rrdata_soa{
                mname = binary_to_name([<<"ns">>|ZoneComponents]), %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = Now, %% Hopefully there is not more than 1 update/sec :)
                refresh = 5,
                retry = 5,
                expire = 5,
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
    {_, Records1} = ets:foldl(fun add_record_fold/2, {ZoneComponents, Records0}, name_to_ip),
    Sha = crypto:hash(sha, term_to_binary(Records1)),
    {ZoneName, Sha, Records1}.

add_record_fold({Name, IPInt}, {ZoneComponents, Records0}) ->
    Record = #dns_rr{
        name = binary_to_name([Name] ++ ZoneComponents),
        type = ?DNS_TYPE_A,
        ttl = 5,
        data = #dns_rrdata_a{
            ip = integer_to_ip(IPInt)
        }
    },
    {ZoneComponents, [Record|Records0]}.

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


-spec(integer_to_ip(IntIP :: 0..4294967295) -> inet:ip4_address()).
integer_to_ip(IntIP) ->
    <<A, B, C, D>> = <<IntIP:32/integer>>,
    {A, B, C, D}.

-spec(ip_to_integer(inet:ip4_address()) -> 0..4294967295).
ip_to_integer(_IP = {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP.


-spec(update_name_mapping(Names :: term(), State :: state()) -> ok).
update_name_mapping(Names, State) ->
    remove_old_names(Names),
    add_new_names(Names, State),
    ok.

%% This can be rewritten as an enumeration over the ets table, and the names passed to it.
remove_old_names(NewNames) ->
    OldNames = lists:sort([Name || {Name, _IP} <- ets:tab2list(name_to_ip)]),
    NamesToDelete = ordsets:subtract(OldNames, NewNames),
    lists:foreach(fun(NameToDelete) -> remove_old_name(NameToDelete) end, NamesToDelete).

remove_old_name(NameToDelete) ->
    [{_, IP}] = ets:lookup(name_to_ip, NameToDelete),
    ets:delete(ip_to_name, IP),
    ets:delete(name_to_ip, NameToDelete).

add_new_names(Names, State) ->
    lists:foreach(fun(Name) -> maybe_add_new_name(Name, State) end, Names).

maybe_add_new_name(Name, State) ->
    case ets:lookup(name_to_ip, Name) of
        [] ->
            add_new_name(Name, State);
        _ ->
            ok
    end.
add_new_name(Name, State = #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    SearchStart = erlang:phash2(Name, MaxIPNum - MinIPNum),
    add_new_name(Name, SearchStart + 1, SearchStart, State).

add_new_name(_Name, SearchNext, SearchStart, #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) when
    SearchNext rem (MaxIPNum - MinIPNum) == SearchStart ->
    throw(out_of_ips);
add_new_name(Name, SearchNext, SearchStart,
        State =
            #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    ActualIPNum = MinIPNum + (SearchNext rem (MaxIPNum - MinIPNum)),
    case ets:lookup(ip_to_name, ActualIPNum) of
        [] ->
            ets:insert(name_to_ip, {Name, ActualIPNum}),
            ets:insert(ip_to_name, {ActualIPNum, Name});
        _ ->
            add_new_name(Name, SearchNext + 1, SearchStart, State)
    end.

ets_restart(Tab) ->
    catch ets:delete(Tab),
    catch ets:new(Tab, [named_table, protected, {read_concurrency, true}]).

-ifdef(TEST).
state() ->
    %% 9/8
    ets_restart(name_to_ip),
    ets_restart(ip_to_name),
    #state{ref = undefined, min_ip_num = 16#0b000000, max_ip_num = 16#0b0000fe}.

process_vips_test() ->
    State = state(),
    VIPs = [
        {
            {{tcp, {1, 2, 3, 4}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, 11778}]
        },
        {
            {{tcp, {name, {<<"/foo">>, <<"marathon">>}}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, 25458}]
        }
    ],
    Out = process_vips(VIPs, State),
    Expected = [
        {{tcp, {1, 2, 3, 4}, 80}, [{{10, 0, 3, 46}, 11778}]},
        {{tcp, {11, 0, 0, 36}, 80}, [{{10, 0, 3, 46}, 25458}]}
    ],
    ?assertEqual(Expected, Out),
    State.

update_name_mapping_test() ->
    State0 = state(),
    update_name_mapping([test1, test2, test3], State0),
    NTIList = [{N, I} || {I, N} <- ets:tab2list(ip_to_name)],
    ?assertEqual(NTIList, ets:tab2list(name_to_ip)),
    ?assertEqual([{184549622, test3}, {184549621, test2}, {184549620, test1}], ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, 184549622}, {test2, 184549621}, {test1, 184549620}], ets:tab2list(name_to_ip)),
    update_name_mapping([test1, test3], State0),
    ?assertEqual([{184549622, test3}, {184549620, test1}], ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, 184549622}, {test1, 184549620}], ets:tab2list(name_to_ip)).


zone_test() ->
    State = process_vips_test(),
    Components = [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    Zone = zone(1463878088, Components, State),
    Expected =
        {<<"l4lb.thisdcos.directory">>,
            <<98, 101, 185, 78, 24, 158, 232, 55, 203, 212, 105, 96, 175, 215, 249, 57, 64, 221, 147, 29>>,
            [
                {dns_rr, <<"foo.marathon.l4lb.thisdcos.directory">>, 1, 1, 5, {dns_rrdata_a, {11, 0, 0, 36}}},
                {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
                    {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>, <<"support.mesosphere.com">>,
                        1463878088, 5, 5, 5, 1}
                },
                {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600, {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
                {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600, {dns_rrdata_a, {198, 51, 100, 1}}}
            ]
        },

    ?assertEqual(Expected, Zone).
%%
%%    Expected = {<<"l4lb.thisdcos.directory">>,
%%        <<161, 204, 13, 14, 64, 13, 80, 62, 140, 205, 206, 161, 238, 57, 215,
%%            246, 172, 97, 183, 176>>,
%%        [{dns_rr, <<"foo4.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%            {dns_rrdata_a, {11, 0, 0, 86}}},
%%            {dns_rr, <<"foo3.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 0}}},
%%            {dns_rr, <<"foo2.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 108}}},
%%            {dns_rr, <<"foo1.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 36}}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
%%                {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>,
%%                    <<"support.mesosphere.com">>, 1463878088, 5, 5, 5, 1}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600,
%%                {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
%%            {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600,
%%                {dns_rrdata_a, {198, 51, 100, 1}}}]},
%%    ?assertEqual(Expected, Zone).
%%
overallocate_test() ->
    State = #state{max_ip_num = Max, min_ip_num = Min} = state(),
    FakeNames = lists:seq(1, Max - Min + 1),
    ?assertThrow(out_of_ips, update_name_mapping(FakeNames, State)).


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

-endif.
