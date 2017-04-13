%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Oct 2016 12:48 AM
%%%-------------------------------------------------------------------
-module(minuteman_lb_mgr).
-author("sdhillon").

-behaviour(gen_statem).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-include("minuteman_lashup.hrl").
-define(SERVER, ?MODULE).

-record(state, {
    last_configured_vips = [],
    last_received_vips = [],
    route_mgr,
    ipvs_mgr,
    route_events_ref,
    kv_ref,
    ip_mapping = #{}:: map(),
    tree            :: lashup_gm_route:tree() | undefined
}).

-type state_data() :: #state{}.

-type state_name() :: uninitialized | initialized | notree.


%% API
-export([start_link/0]).
-export([push_vips/1]).


%% gen_statem behaviour
-export([init/1, terminate/3, code_change/4, callback_mode/0]).

%% State callbacks
-export([notree/3, no_ips/3, reconcile/3, maintain/3]).

-ifdef(TEST).
-export([normalize_services_and_dests/1]).
-endif.

push_vips(VIPs0) ->
    VIPs1 = ordsets:from_list(VIPs0),
    gen_statem:cast(?SERVER, {vips, VIPs1}).

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(init([]) -> {ok, state_name(), state_data()}).
init([]) ->
    {ok, KVRef} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?NODEMETADATA_KEY}) -> true end)),
    {ok, Ref} = lashup_gm_route_events:subscribe(),
    {ok, IPVSMgr} = minuteman_ipvs_mgr:start_link(),
    {ok, RouteMgr} = minuteman_route_mgr:start_link(),
    State = #state{route_mgr = RouteMgr, ipvs_mgr = IPVSMgr, route_events_ref = Ref, kv_ref = KVRef},
    {ok, notree, State}.

terminate(Reason, State, Data) ->
    lager:warning("Terminating, due to: ~p, in state: ~p, with state data: ~p", [Reason, State, Data]).

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

callback_mode() ->
    state_functions.

%% TODO: We need to do lashup integration and make it so there are availability checks


%handle_event(EventType, EventContent, StateName, #state{}) ->
%% In the uninitialized state, we want to enumerate the VIPs that exist,
%% and we want to delete the VIPs that aren't in the list
%% Then we we redeliver the event for further processing
%% VIPs are in the structure [{{protocol(), inet:ipv4_address(), port_num}, [{inet:ipv4_address(), port_num}]}]
%% [{{tcp,{1,2,3,4},80},[{{33,33,33,2},20320}]}]

%% States go notree -> no_ips -> reconcile -> maintain
notree(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    State1 = State0#state{tree = Tree},
    {next_state, reconcile, State1};
notree(_, _, _) ->
    {keep_state_and_data, postpone}.

no_ips(info, {lashup_kv_events, Event = #{ref := Ref}}, State0 = #state{kv_ref = Ref}) ->
    State1 = handle_ip_event(Event, State0),
    {next_state, reconcile, State1};
no_ips(_, _, _) ->
    {keep_state_and_data, postpone}.


reconcile(cast, {vips, VIPs}, State0) ->
    State1 = do_reconcile(VIPs, State0),
    {next_state, maintain, State1};
reconcile(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    State1 = State0#state{tree = Tree},
    {keep_state, State1};
reconcile(info, {lashup_kv_events, Event = #{ref := Ref}}, State0 = #state{kv_ref = Ref}) ->
    State1 = handle_ip_event(Event, State0),
    {keep_state, State1}.

maintain(cast, {vips, VIPs}, State0) ->
    State1 = maintain(VIPs, State0),
    {keep_state, State1};
maintain(internal, maintain, State0 = #state{last_received_vips = VIPs}) ->
    State1 = maintain(VIPs, State0),
    {keep_state, State1};
maintain(info, {lashup_gm_route_events, #{ref := Ref, tree := Tree}}, State0 = #state{route_events_ref = Ref}) ->
    State1 = State0#state{tree = Tree},
    {keep_state, State1, {next_event, internal, maintain}};
maintain(info, {lashup_kv_events, Event = #{ref := Ref}}, State0 = #state{kv_ref = Ref}) ->
    State1 = handle_ip_event(Event, State0),
    {keep_state, State1}.

do_reconcile(VIPs, State0) ->
    do_reconcile_routes(VIPs, State0),
    do_reconcile_services(VIPs, State0).

%% TODO: Refactor
do_reconcile_routes(VIPs, #state{route_mgr = RouteMgr}) ->
    ExpectedIPs = ordsets:from_list([VIP || {{_Proto, VIP, _Port}, _Backends} <- VIPs]),
    minuteman_route_mgr:update_routes(RouteMgr, ExpectedIPs).

%% Converts IPVS service / dests into our normal minuteman ones
normalize_services_and_dests({Service0, Destinations0}) ->
    Service1 = minuteman_ipvs_mgr:service_address(Service0),
    Destinations1 = lists:map(fun minuteman_ipvs_mgr:destination_address/1, Destinations0),
    Destinations2 = lists:usort(Destinations1),
    {Service1, Destinations2}.

do_reconcile_services(VIPs0, State0 = #state{ipvs_mgr = _IPVSMgr}) ->
    InstalledState = installed_state(State0),
    VIPs1 = process_reachability(VIPs0, State0),
    Diff = generate_diff(InstalledState, VIPs1),
    apply_diff(Diff, State0),
    State0#state{last_received_vips = VIPs0, last_configured_vips = VIPs1}.

apply_diff({ServicesToAdd, ServicesToRemove, ServicesToModify}, State) ->
    lists:foreach(fun({VIP, _BEs}) -> remove_service(VIP, State) end, ServicesToRemove),
    lists:foreach(fun({VIP, BEs}) -> add_service(VIP, BEs, State) end, ServicesToAdd),
    lists:foreach(fun({VIP, BEAdd, BERemove}) -> modify_service(VIP, BEAdd, BERemove, State) end, ServicesToModify).

modify_service({Protocol, IP, Port}, BEAdd, BERemove, #state{ipvs_mgr = IPVSMgr}) ->
    lists:foreach(
        fun({_AgentIP, {BEIP, BEPort}}) ->
                minuteman_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol)
        end,
        BEAdd),
    lists:foreach(
        fun({_AgentIP, {BEIP, BEPort}}) ->
                minuteman_ipvs_mgr:remove_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol)
        end,
        BERemove).


remove_service({Protocol, IP, Port}, #state{ipvs_mgr = IPVSMgr}) ->
    minuteman_ipvs_mgr:remove_service(IPVSMgr, IP, Port, Protocol).

add_service({Protocol, IP, Port}, BEs, #state{ipvs_mgr = IPVSMgr}) ->
    minuteman_ipvs_mgr:add_service(IPVSMgr, IP, Port, Protocol),
    lists:foreach(
      fun({_AgentIP, {BEIP, BEPort}}) ->
              minuteman_ipvs_mgr:add_dest(IPVSMgr, IP, Port, BEIP, BEPort, Protocol)
      end,
      BEs).

process_reachability(VIPs0, State) ->
    lists:map(fun({VIP, BEs0}) -> {VIP, reachable_backends(BEs0, State)} end, VIPs0).

installed_state(#state{ipvs_mgr = IPVSMgr}) ->
    Services = minuteman_ipvs_mgr:get_services(IPVSMgr),
    ServicesAndDests0 = [{Service, minuteman_ipvs_mgr:get_dests(IPVSMgr, Service)} || Service <- Services],
    ServicesAndDests1 = lists:map(fun normalize_services_and_dests/1, ServicesAndDests0),
    lists:usort(ServicesAndDests1).

maintain(VIPs0, State0 = #state{last_configured_vips = LastConfigured}) ->
    VIPs1 = process_reachability(VIPs0, State0),
    lager:debug("Last Configured: ~p", [LastConfigured]),
    lager:debug("VIPs1: ~p", [VIPs1]),
    Diff = generate_diff(LastConfigured, VIPs1),
    lager:debug("Diff: ~p", [Diff]),
    apply_diff(Diff, State0),
    do_reconcile_routes(VIPs1, State0),
    State0#state{last_configured_vips = VIPs1, last_received_vips = VIPs0}.


%% Returns {VIPsToRemove, VIPsToAdd, [VIP, BackendsToRemove, BackendsToAdd]}
generate_diff(Lhs, Rhs) ->
    generate_diff(Lhs, Rhs, [], [], []).

%% Prepare for mutation
%generate_diff([{VIPLhs, BELhs}|RestLhs], [{VIPRhs, BERhs}|RestRhs], VIPToAdd, VIPToRemove, Mutation)

%% The VIPs are equal AND the backends are equal. Ignore it.
generate_diff([{VIP, BE}|RestLhs], [{VIP, BE}|RestRhs], VIPsToAdd, VIPsToRemove, Mutations) ->
    generate_diff(RestLhs, RestRhs, VIPsToAdd, VIPsToRemove, Mutations);
%% VIPs are equal, but the backends are different, prepare a mutation entry
generate_diff([{VIP, BELhs}|RestLhs], [{VIP, BERhs}|RestRhs], VIPsToAdd, VIPsToRemove, Mutations0) ->
    BERhs1 = ordsets:from_list(BERhs),
    BELhs1 = ordsets:from_list(BELhs),
    BEToAdd = ordsets:subtract(BERhs1, BELhs1),
    BEToRemove = ordsets:subtract(BELhs1, BERhs1),
    Mutation = {VIP, BEToAdd, BEToRemove},
    generate_diff(RestLhs, RestRhs, VIPsToAdd, VIPsToRemove, [Mutation|Mutations0]);
%% New VIP
generate_diff(Lhs = [VIPLhs|_RestLhs], [VIPRhs|RestRhs], VIPsToAdd0, VIPsToRemove, Mutations) when VIPRhs > VIPLhs ->
    generate_diff(Lhs, RestRhs, [VIPRhs|VIPsToAdd0], VIPsToRemove, Mutations);
%% To delete VIP
generate_diff([VIPLhs|RestLhs], Rhs = [VIPRhs|_RestRhs], VIPsToAdd, VIPsToRemove0, Mutations) when VIPRhs < VIPLhs ->
    generate_diff(RestLhs, Rhs, VIPsToAdd, [VIPLhs|VIPsToRemove0], Mutations);
generate_diff([], [], VIPsToAdd, VIPsToRemove, Mutations) ->
    {VIPsToAdd, VIPsToRemove, Mutations};
generate_diff([], Rhs, VIPsToAdd0, VIPsToRemove, Mutations) ->
    {VIPsToAdd0 ++ Rhs, VIPsToRemove, Mutations};
generate_diff(Lhs, [], VIPsToAdd, VIPsToRemove0, Mutations) ->
    {VIPsToAdd, VIPsToRemove0 ++ Lhs, Mutations}.

handle_ip_event(_Event = #{value := Value}, State0) ->
    IPToNodeName = [{IP, NodeName} || {?LWW_REG(IP), NodeName} <- Value],
    IPMapping = maps:from_list(IPToNodeName),
    State0#state{ip_mapping = IPMapping}.

reachable_backends(Backends, State) ->
    reachable_backends(Backends, [], [], State).

reachable_backends([], _OpenBackends = [], ClosedBackends, _State) ->
    ClosedBackends;
reachable_backends([], OpenBackends, _ClosedBackends, _State) ->
    OpenBackends;
reachable_backends([BE = {IP, {_BEIP, _BEPort}}|Rest], OB, CB, State = #state{ip_mapping = IPMapping, tree = Tree}) ->
    case IPMapping of
        #{IP := NodeName} ->
            case lashup_gm_route:distance(NodeName, Tree) of
                infinity ->
                    reachable_backends(Rest, OB, [BE|CB], State);
                _ ->
                    reachable_backends(Rest, [BE|OB], CB, State)
            end;
        _ ->
            reachable_backends(Rest, OB, [BE|CB], State)
    end.

-ifdef(TEST).

generate_diffs_test() ->
    ?assertEqual({[], [], []}, generate_diff([], [])),
    ?assertEqual({[], [], [{a, [4], [1]}]}, generate_diff([{a, [1, 2, 3]}], [{a, [2, 3, 4]}])),
    ?assertEqual({[], [{b, [1, 2, 3]}], []}, generate_diff([{b, [1, 2, 3]}], [])),
    ?assertEqual({[{b, [1, 2, 3]}], [], []}, generate_diff([], [{b, [1, 2, 3]}])),
    ?assertEqual({[], [], []}, generate_diff([{a, [1, 2, 3]}], [{a, [1, 2, 3]}])),
    ?assertEqual({[{b, []}], [{a, []}, {c, []}], []}, generate_diff([{a, []}, {c, []}], [{b, []}])),
    Diff1 =
        generate_diff(
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 8895}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 16319}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 3892}}
                    ]
                }
            ],
            [
                {{tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 8895}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 16319}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 15671}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 3892}}
                    ]
                }
            ]),
    ?assertEqual(
        {[], [], [{{tcp, {11, 136, 231, 163}, 80}, [{{10, 0, 1, 107}, {{10, 0, 1, 107}, 15671}}], []}]}, Diff1),
    Diff2 =
        generate_diff(
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 23520}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 1132}}
                    ]
                }
            ],
            [
                {
                    {tcp, {11, 136, 231, 163}, 80},
                    [
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 23520}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 12930}},
                        {{10, 0, 3, 98}, {{10, 0, 3, 98}, 1132}},
                        {{10, 0, 1, 107}, {{10, 0, 1, 107}, 18818}}
                    ]
                }
            ]),
    ?assertEqual(
        {[], [], [{{tcp, {11, 136, 231, 163}, 80},
                     [{{10, 0, 1, 107}, {{10, 0, 1, 107}, 18818}},
                      {{10, 0, 3, 98}, {{10, 0, 3, 98}, 12930}}],
         []}]}, Diff2).
-endif.
