%%%-------------------------------------------------------------------
%%% @author Anatoly Yakovenko
%%% @copyright (C) 2016, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 24. Oct 2016 11:42 AM
%%%-------------------------------------------------------------------
-module(minuteman_metrics).
-author("Anatoly Yakovenko").

-include_lib("telemetry/include/telemetry.hrl").
-include_lib("ip_vs_conn/include/ip_vs_conn.hrl").

-export([start_link/0]).

-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-type backend_conns() :: #{inet:ip4_address() => [#ip_vs_conn{}]}.
-type metrics() :: []. %% netlink record

-record(state, {
          conns = maps:new() :: conn_map(),
          backend_conns = maps:new() :: backend_conns()
    }).

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(init(term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |

    {stop, Reason :: term()} | ignore).
init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(splay_ms(), self(), push_metrics),
    {ok, #state{}}.

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

-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
    {noreply, State}.

-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(push_metrics, State = #state{}) ->
    ok = ip_vs_conn_monitor:get_connections(update_connections),
    erlang:send_after(splay_ms(), self(), push_metrics),
    {noreply, State};
handle_info({update_metrics, Metrics}, State = #state{}) ->
    update_metrics(State#state.backend_conns, Metrics),
    {noreply, State};
handle_info({update_connections, Conns}, State = #state{}) ->
    {NewConns, NewBackends} = update_connections(State#state.conns, Conns),
    erlang:send_after(1, self(), start_update_metrics),
    {noreply, State#state{conns = NewConns, backend_conns = NewBackends}};
handle_info(start_update_metrics, State) ->
    ok = tcp_metrics_monitor:get_metrics(update_metrics),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
    ok.

-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% TODO: borrowed from minuteman, should probably be a util somewhere
-spec(splay_ms() -> integer()).
splay_ms() ->
    MsPerMinute = minuteman_config:metrics_interval_seconds() * 1000,
    NextMinute = -1 * erlang:monotonic_time(milli_seconds) rem MsPerMinute,
    SplayMS = minuteman_config:metrics_splay_seconds() * 1000,
    FlooredSplayMS = max(1, SplayMS),
    Splay = rand:uniform(FlooredSplayMS),
    NextMinute + Splay.

%% implementation
-spec(update_connections(conn_map(), conn_map()) -> {conn_map(), backend_conns()}).
update_connections(OldConns, Conns) ->
    Splay = minuteman_config:metrics_splay_seconds(),
    Interval = minuteman_config:metrics_interval_seconds(),
    PollDelay = (Splay + Interval),
    OnlyNewConns = new_connections(PollDelay, OldConns, Conns),
    Parsed = lists:map(fun ip_vs_conn:parse/1, maps:to_list(OnlyNewConns)),
    lists:foreach(fun (C) -> record_connection(C) end, Parsed),
    NewBackends = dst_ip_map(Parsed),
    OpenedOrDead = opened_or_dead(PollDelay, Conns),
    {OpenedOrDead, NewBackends}.

-spec(update_metrics(conn_map(), metrics()) -> [{#ip_vs_conn{}, integer(), integer()}]).
update_metrics(Backends, Metrics) ->
    P99s = get_p99s(Backends, Metrics),
    lists:flatmap(fun apply_p99/1, P99s).

dst_ip_map(Parsed) ->
    lists:foldl(fun vip_addr_map/2, #{}, Parsed).

vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z) ->
    vip_addr_map(C, Z, maps:get(int_to_ip(IP), Z, undefined)).

vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z, undefined) ->
    maps:put(int_to_ip(IP), [C], Z);
vip_addr_map(C = #ip_vs_conn{dst_ip = IP}, Z, Ls) ->
    maps:put(int_to_ip(IP), [C | Ls], Z).

new_connections(PD, Conns, AllConns) ->
    maps:filter(fun(K, V) -> new_connection(PD, Conns, {K, V}) end, AllConns).

%% only process new connections, or half opened connections that are about to expire
new_connection(PD, Conns, {K, V}) -> not(maps:is_key(K, Conns)) and (is_opened({K, V}) or is_dead(PD, {K, V})).

%% only dead if its half opened and about to expire
is_dead(PD, {K, V=#ip_vs_conn_status{tcp_state = syn_recv}}) ->
    Conn = ip_vs_conn:parse({K, V}),
    PD > Conn#ip_vs_conn.expires;
is_dead(PD, {K, V=#ip_vs_conn_status{tcp_state = syn_sent}}) ->
    Conn = ip_vs_conn:parse({K, V}),
    PD > Conn#ip_vs_conn.expires;
is_dead(_PD, _KV) -> false.

%% only opened if its not half opened
is_opened({_K, #ip_vs_conn_status{tcp_state = syn_recv}}) -> false;
is_opened({_K, #ip_vs_conn_status{tcp_state = syn_sent}}) -> false;
is_opened(_KV) -> true.

-spec(opened_or_dead(integer(), conn_map()) -> conn_map()).
opened_or_dead(PD, Conns) ->
    maps:filter(fun(K, V) -> is_opened({K, V}) or is_dead(PD, {K, V}) end, Conns).

-spec(record_connection(#ip_vs_conn{})-> ok).
record_connection(Conn = #ip_vs_conn{tcp_state = syn_recv}) ->
    conn_failed(Conn);
record_connection(Conn = #ip_vs_conn{tcp_state = syn_sent}) ->
    conn_failed(Conn);
record_connection(Conn) ->
    conn_success(Conn).

-spec(conn_failed(#ip_vs_conn{}) -> ok).
conn_failed(#ip_vs_conn{dst_ip = IP, dst_port = Port,
                        to_ip = VIP, to_port = VIPPort}) ->
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_failures, Tags, AggTags, 1).

-spec(conn_success(#ip_vs_conn{}) -> ok).
conn_success(#ip_vs_conn{dst_ip = IP, dst_port = Port,
                         to_ip = VIP, to_port = VIPPort}) ->
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_successes, Tags, AggTags, 1).

get_p99s(Conns, Metrics) ->
    lists:flatmap(fun (M) -> get_p99_updates(Conns, M) end, Metrics).

get_p99_updates(Conns, {netlink, tcp_metrics, _, _, _, {get, _, _, Attrs}}) ->
    match_metrics(Conns, proplists:get_value(d_addr, Attrs), proplists:get_value(vals, Attrs)).

match_metrics(_, undefined, _) -> [];
match_metrics(_, _, undefined) -> [];
match_metrics(Conns, Addr, Vals) -> match_conn(maps:get(Addr, Conns, undefined),
                                               proplists:get_value(rtt_us, Vals),
                                               proplists:get_value(rtt_var_us, Vals)).
match_conn(undefined, _, _) -> [];
match_conn(_, undefined, _) -> [];
match_conn(_, _, undefined) -> [];
match_conn(Conns, RttUs, RttVarUs) -> [{Conns, RttUs, RttVarUs}].

apply_p99({Conns, RttUs, RttVarUs}) ->
    lists:flatmap(fun(C) -> apply_p99(C, RttUs, RttVarUs) end, Conns).

apply_p99(C = #ip_vs_conn{dst_ip = IP, dst_port = Port,
                          to_ip = VIP, to_port = VIPPort},
          RttUs, RttVarUs) ->
    P99 = erlang:round(1000*(RttUs + math:sqrt(RttVarUs)*3)),
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:histogram(mm_connect_latency, Tags, AggTags, P99),
    [{C, RttUs, RttVarUs}].


-spec(named_tags(IIP :: integer(),
                 Port :: inet:port_numbrer(),
                 IVIP :: integer(),
                 VIPPort :: inet:port_numbrer()) -> map:map()).
named_tags(IIP, Port, IVIP, VIPPort) ->
    IP = int_to_ip(IIP),
    VIP = int_to_ip(IVIP),
    case minuteman_lashup_vip_listener:lookup_vips([{ip, VIP}]) of
        [{name, VIPName}] -> #{vip => fmt_ip_port(VIP, VIPPort), backend => fmt_ip_port(IP, Port), name => VIPName};
        _ -> #{vip => fmt_ip_port(VIP, VIPPort), backend => fmt_ip_port(IP, Port)}
    end.

int_to_ip(Int) -> minuteman_lashup_vip_listener:integer_to_ip(Int).

-spec(fmt_ip_port(IP :: inet:ip4_address(), Port :: inet:port_number()) -> binary()).
fmt_ip_port(IP, Port) ->
    IPString = inet_parse:ntoa(IP),
    List = io_lib:format("~s_~p", [IPString, Port]),
    list_to_binary(List).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

new_conn_test_() ->
    Conn = <<"TCP 0A004FB6 F26D 0A004FB6 1F90 0A004FB6 1F91 ">>,
    ConnStatus = #ip_vs_conn_status{conn_state = <<"50 ">>, tcp_state = established},
    [?_assertEqual(#{Conn => ConnStatus}, new_connections(100, #{}, #{Conn => ConnStatus})),
     ?_assertEqual(#{Conn => ConnStatus}, new_connections(0, #{}, #{Conn => ConnStatus})),
     ?_assertEqual(#{}, new_connections(100, #{Conn => ConnStatus}, #{Conn => ConnStatus})),
     ?_assertEqual(#{}, new_connections(0, #{Conn => ConnStatus}, #{Conn => ConnStatus}))].

new_conn1_test_() ->
    Conn = <<"TCP 0A004FB6 F26D 0A004FB6 1F90 0A004FB6 1F91 ">>,
    ConnStatus1 = #ip_vs_conn_status{conn_state = <<"50 ">>, tcp_state = syn_recv},
    ConnStatus2 = #ip_vs_conn_status{conn_state = <<"50 ">>, tcp_state = syn_sent},
    [?_assertEqual(true, is_dead(100, {Conn, ConnStatus1})),
     ?_assertEqual(false, is_dead(0, {Conn, ConnStatus1})),
     ?_assertEqual(false, is_opened({Conn, ConnStatus1})),
     ?_assertEqual(#{Conn => ConnStatus1}, new_connections(100, #{}, #{Conn => ConnStatus1})),
     ?_assertEqual(#{Conn => ConnStatus2}, new_connections(100, #{}, #{Conn => ConnStatus2})),
     ?_assertEqual(#{}, new_connections(25, #{}, #{Conn => ConnStatus2})),
     ?_assertEqual(#{}, new_connections(25, #{Conn => ConnStatus2}, #{Conn => ConnStatus2})),
     ?_assertEqual(#{}, new_connections(100, #{Conn => ConnStatus2}, #{Conn => ConnStatus2}))
    ].

get_p99s_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_us, 23656},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    DAddr = int_to_ip(IP),
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([{[Conn], 47313, 23656}], get_p99s(ConnMap, Metrics)),
     ?_assertEqual([{[Conn, Conn2], 47313, 23656}], get_p99s(ConnMap2, Metrics))].

process_p99s_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_us, 23656},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([{Conn, 47313, 23656}], update_metrics(ConnMap, Metrics)),
     ?_assertEqual([{Conn, 47313, 23656}, {Conn2, 47313, 23656}], update_metrics(ConnMap2, Metrics)),
     ?_assertEqual([], update_metrics(#{}, Metrics))
    ].

process_p99s_1_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_us, 47313},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], update_metrics(ConnMap, Metrics)),
     ?_assertEqual([], update_metrics(ConnMap2, Metrics))
    ].

process_p99s_2_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_var_us, 23656},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], update_metrics(ConnMap, Metrics)),
     ?_assertEqual([], update_metrics(ConnMap2, Metrics))
    ].

process_p99s_3_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408},
             {vals, [{rtt_var_us, 23656},
                    {rtt_ms, 47},
                    {rtt_var_ms, 23},
                    {cwnd, 10}]}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], update_metrics(ConnMap, Metrics)),
     ?_assertEqual([], update_metrics(ConnMap2, Metrics))
    ].

process_p99s_4_test_() ->
    DAddr = {54, 192, 147, 29},
    Attrs = [{d_addr, DAddr},
             {s_addr, {10, 0, 79, 182}},
             {age_ms, 806101408}],
    Metrics = [{netlink, tcp_metrics, [multi], 18, 31595, {get, 1, 0, Attrs}}],
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn, Conn2]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual([], update_metrics(ConnMap, Metrics)),
     ?_assertEqual([], update_metrics(ConnMap2, Metrics))
    ].

process_dst_ip_map_test_() ->
    DAddr = {54, 192, 147, 29},
    IP = 16#36c0931d,
    Conn = {ip_vs_conn, tcp, established, 167792566, 47808, 167792566, 8080, IP, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, established, 167792567, 47808, 167792566, 8080, IP, 8081, 59},
    ConnMap = #{DAddr => [Conn]},
    ConnMap2 = #{DAddr => [Conn2, Conn]},
    [?_assertEqual(DAddr, int_to_ip(IP)),
     ?_assertEqual(ConnMap, dst_ip_map([Conn])),
     ?_assertEqual(ConnMap2, dst_ip_map([Conn, Conn2]))
    ].

record_failed_test_() ->
    Conn1 = {ip_vs_conn, tcp, syn_sent, 167792566, 47808, 167792566, 8080, 167792566, 8081, 59},
    Conn2 = {ip_vs_conn, tcp, syn_recv, 167792567, 47808, 167792566, 8080, 167792566, 8081, 59},
    [?_assertEqual(ok, record_connection(Conn1)),
     ?_assertEqual(ok, record_connection(Conn2))].

-endif.
