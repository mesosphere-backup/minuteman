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

-record(state, {
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
    check_connections(),
    erlang:send_after(splay_ms(), self(), push_metrics),
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
-spec(check_connections() -> ok).
check_connections() ->
    {ok, Conns} = ip_vs_conn_monitor:get_connections(),
    ct:pal("got connections ~p", [Conns]),
    Parsed = maps:fold(fun(K,V,Z) -> [{ip_vs_conn:parse(K),V}|Z] end, [], Conns),
    ct:pal("got parsed ~p", [Parsed]),
    lists:foreach(fun check_connections/1, Parsed).

-spec(check_connections({#ip_vs_conn{}, #ip_vs_conn_status{}}) -> ok).
check_connections({Conn, #ip_vs_conn_status{tcp_state = syn_recv}}) ->
    conn_failed(Conn);
check_connections({Conn, Status = #ip_vs_conn_status{tcp_state = time_wait}}) ->
    conn_success(Conn, Status);
check_connections({Conn, Status = #ip_vs_conn_status{tcp_state = close_wait}}) ->
    conn_success(Conn, Status);
check_connections({Conn, Status = #ip_vs_conn_status{tcp_state = established}}) ->
    conn_success(Conn, Status).

-spec(conn_failed(#ip_vs_conn{}) -> ok).
conn_failed(#ip_vs_conn{from_ip = IP, from_port = Port,
                        to_ip = VIP, to_port = VIPPort}) ->
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_failures, Tags, AggTags, 1).

-spec(conn_success(#ip_vs_conn{}, #ip_vs_conn_status{}) -> ok).
conn_success(#ip_vs_conn{from_ip = IP, from_port = Port,
                         to_ip = VIP, to_port = VIPPort},
             #ip_vs_conn_status{time_ns = Time}) ->
    TimeDelta = erlang:monotonic_time(nano_seconds) - Time,
    Tags = named_tags(IP, Port, VIP, VIPPort),
    AggTags = [[hostname], [hostname, backend]],
    telemetry:counter(mm_connect_successes, Tags, AggTags, 1),
    telemetry:histogram(mm_connect_latency, Tags, AggTags, TimeDelta).


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


