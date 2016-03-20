%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 9:00 PM
%%%-------------------------------------------------------------------
-module(minuteman_mesos_poller).
-author("sdhillon").
-author("Tyler Neely").

-behaviour(gen_server).

-compile(export_all).
%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).

-record(state, {
          vips = orddict:new(),
          last_master_elected = 0,
          last_master_elected_local_time = erlang:monotonic_time(seconds),
          agent_cache = maps:new()
         }).

-record(agent_cache, {
          last_seen_time = 0,
          last_seen_tasks = [],
          last_seen_ips = []
         }).

%% Debug
-export([poll/1]).

-type task() :: map().
-type task_status() :: map().
-type label() :: map().
-type network_info() :: map().
-type vip_string() :: <<_:48, _:_*1>>.

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
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  ok = timer:start(),
  {ok, _} = timer:send_after(minuteman_config:poll_interval(), poll),
  %% 64MB
  process_flag(min_heap_size, 8000000),
  process_flag(priority, low),
  {ok, #state{}}.

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
handle_info(poll, State) ->
  NewState = case poll(State) of
    {error, Reason} ->
      lager:warning("Could not poll: ~p", [Reason]),
      State;
    {ok, RefreshedState} ->
      RefreshedState
  end,
  {noreply, NewState};
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

%%--------------------------------------------------------------------
%% @doc
%% Poll the mesos master for current agents and tasks.  We will compare
%% these tasks against a cache stored in #state{}, which allows us to
%% retain tasks across master failover before agents reregister.
%% @end
%%--------------------------------------------------------------------
-spec(poll(State :: #state{}) -> {ok, #state{}} | {error, http_error}).
poll(State) ->
  lager:debug("Starting poll cycle"),
  {ok, _} = timer:send_after(minuteman_config:poll_interval(), poll),
  MasterURI = minuteman_config:master_uri(),
  Response = httpc:request(get, {MasterURI, []}, [], [{body_format, binary}]),
  case handle_response(State, Response) of
    {ok, NewState = #state{vips = Vips}} ->
      minuteman_vip_events:push_vips(Vips),
      {ok, NewState};
    Other ->
      Other
  end.


%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_response(State, {ok, {{_HttpVersion, 200, _ReasonPhrase}, _Headers, Body}}) ->
  Now = erlang:monotonic_time(seconds),
  NewState = parse_json_to_vips(State, Body, Now),
  {ok, NewState};
handle_response(_State, Response) ->
  lager:debug("Bad HTTP Response: ~p", [Response]),
  {error, http_error}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If a master has been seen for longer than the agent reregistration
%% timeout, we can expect any previously-seen agents to have checked-in.
%% If they have not, the mesos master will kill its tasks if it
%% reregisters in the future. Because these tasks are marked-for-death
%% we can safely remove them from our cache.
%% @end
%%--------------------------------------------------------------------
-spec(filter_old_agents(State :: #state{}, ElectedTime :: float(), Now :: integer()) -> #state{}).
filter_old_agents(State = #state{last_master_elected = LastMaster,
                                 last_master_elected_local_time = LastMasterTime,
                                 agent_cache = AgentCache},
                 ElectedTime, Now) ->
  ReregistrationThreshold = minuteman_config:agent_reregistration_threshold(),
  LastMasterCanKillOldAgents = Now - LastMasterTime >= ReregistrationThreshold,
  case {ElectedTime == LastMaster, LastMasterCanKillOldAgents} of
    {false, _} ->
      State#state{last_master_elected = ElectedTime,
                  last_master_elected_local_time = Now};
    {true, true} ->
      %% This master is old enough to have invalidated any tasks on
      %% slaves that have not yet reconnected.
      FilterFunc = fun (_ID, #agent_cache{last_seen_time = LastSeenTime}) ->
                       Now - LastSeenTime < ReregistrationThreshold
                   end,
      PrunedCache = maps:filter(FilterFunc, AgentCache),
      State#state{agent_cache = PrunedCache};
    {true, _} ->
      %% This master is not old enough to trust with agent evictions
      State
  end.

-spec(parse_json(Data :: binary()) -> {float(), list(map()), list(map())}).
parse_json(Data) ->
  Parsed = jsx:decode(Data, [return_maps, {labels, atom}]),
  ElectedTime = maps:get(elected_time, Parsed),
  Agents = maps:get(slaves, Parsed),
  Frameworks = maps:get(frameworks, Parsed),
  {ElectedTime, Agents, Frameworks}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Conditionally prune the agent cache and merge it with the previous
%% results from the mesos master to retrieve the current set of VIPs.
%% @end
%%--------------------------------------------------------------------
-spec(parse_json_to_vips(State :: #state{}, Data :: binary(), Now :: integer()) -> #state{}).
parse_json_to_vips(State, Data, Now) ->
  {ElectedTime, Agents, Frameworks} = parse_json(Data),

  %% Filter agents if we have seen this master for long enough for it
  %% to have marked an agent as being down.
  State2 = filter_old_agents(State, ElectedTime, Now),

  FrameworkTasks = lists:flatmap(fun (#{tasks := Tasks}) -> Tasks end, Frameworks),
  RawActiveAgents = lists:filter(fun(Agent) -> maps:get(active, Agent) end, Agents),

  %% Get a map from agent ID to #agent_cache{}, we will trust these active agents
  ActiveAgents = agents_to_agent_caches(RawActiveAgents, FrameworkTasks, Now),

  %% Merge the detected active agents with the cached, possibly-wandering ones.
  CachedAgents = State2#state.agent_cache,
  MergedAgentCache = maps:merge(CachedAgents, ActiveAgents),
  AgentIPs = get_agent_ips(MergedAgentCache),
  FoldFun = task_fold_fun(AgentIPs),

  State3 = State2#state{agent_cache = MergedAgentCache},

  MergedTasks = maps:fold(fun (_Agent, #agent_cache{last_seen_tasks = AgentTasks}, AccIn) ->
                              lists:flatten([AgentTasks | AccIn])
                          end, [], MergedAgentCache),

  Vips = lists:foldl(FoldFun, orddict:new(), MergedTasks),

  State3#state{vips = Vips}.

agents_to_agent_caches(RawActiveAgents, FrameworkTasks, Now) ->
  FoldFunc = fun(#{pid := Pid, id := Id}, AccIn) ->
                 AgentTasks = lists:filter(fun (Task) ->
                                               TaskAgent = maps:get(slave_id, Task),
                                               TaskAgent == Id
                                           end, FrameworkTasks),
                 IP = libprocess_pid_to_ip(Pid),
                 AccIn#{Id => #agent_cache{last_seen_time = Now,
                                           last_seen_tasks = AgentTasks,
                                           last_seen_ips = IP}}
             end,

  lists:foldl(FoldFunc, #{}, RawActiveAgents).


libprocess_pid_to_ip(LibprocessPid) when is_binary(LibprocessPid) ->
  libprocess_pid_to_ip(binary_to_list(LibprocessPid));
libprocess_pid_to_ip(LibprocessPid) ->
  [_, HostPort] = string:tokens(LibprocessPid, "@"),
  [Host, _Port] = string:tokens(HostPort, ":"),
  {ok, IP} = inet:parse_ipv4_address(Host),
  IP.


get_agent_ips(AgentCache) ->
  FoldFun = fun(ID, #agent_cache{last_seen_ips = IP}, AccIn) ->
                orddict:store(ID, [IP], AccIn)
            end,
  maps:fold(FoldFun, orddict:new(), AgentCache).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Wrapper fun to make task_fold into a higher order function
%% It's a separate function to avoid capturing excessive
%% local variables
%% @end
%%--------------------------------------------------------------------
task_fold_fun(AgentIPs) ->
  fun (Task, Acc) ->
    try task_fold(AgentIPs, Task, Acc) of
      Acc2 -> Acc2
    catch Error:Exception ->
      lager:warning("Got error ~p:~p, while parsing task: ~p", [Error, Exception, Task]),
      Acc
    end
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get the set of VIP mappings corresponding to a task.
%% @end
%%--------------------------------------------------------------------
-spec task_fold(AgentIPs :: orddict:orddict(), [task()], orddict:orddict()) -> orddict:orddict().
task_fold(_AgentIPs, _Task = #{statuses := []}, AccIn) ->
  AccIn;
task_fold(AgentIPs, Task, AccIn) ->
  Acc1 = task_fold_discovery(AgentIPs, Task, AccIn),
  task_fold_labels(AgentIPs, Task, Acc1).


task_fold_discovery(AgentIPs, _Task = #{
  container := #{docker := #{network := <<"BRIDGE">>}},
  slave_id := SlaveID,
  discovery := Discovery,
  statuses := Statuses,
  state := <<"TASK_RUNNING">>}, AccIn) ->
  %% we only care about the most recent status, which will be the last in the list
  [Status|_] = lists:reverse(Statuses),
  IPs = orddict:fetch(SlaveID, AgentIPs),
  vip_discovery(IPs, Status, Discovery, AccIn);
task_fold_discovery(_AgentIPs, _Task = #{
  discovery := Discovery,
  statuses := Statuses,
  state := <<"TASK_RUNNING">>}, AccIn) ->
  [Status|_] = lists:reverse(Statuses),
  IPs = status_to_ips(Status),
  vip_discovery(IPs, Status, Discovery, AccIn);
task_fold_discovery(_AgentIPs, _Task, AccIn) ->
  AccIn.

task_fold_labels(AgentIPs, _Task = #{
            container := #{docker := #{network := <<"BRIDGE">>}},
            slave_id := SlaveID,
            labels := Labels,
            resources  := #{ports := Ports},
            statuses := Statuses,
            state := <<"TASK_RUNNING">>}, AccIn) ->
  %% we only care about the most recent status, which will be the last in the list
  [Status|_] = lists:reverse(Statuses),
  IPs = orddict:fetch(SlaveID, AgentIPs),
  vip_permutations(IPs, Status, Ports, Labels, AccIn);

task_fold_labels(_AgentIPs, _Task = #{
            labels := Labels,
            resources  := #{ports := Ports},
            statuses := Statuses,
            state := <<"TASK_RUNNING">>}, AccIn) ->
  %% we only care about the most recent status, which will be the last in the list
  [Status|_] = lists:reverse(Statuses),
  IPs = status_to_ips(Status),
  vip_permutations(IPs, Status, Ports, Labels, AccIn);

task_fold_labels(_AgentIPs, _Task, AccIn) ->
  AccIn.

-spec vip_permutations([inet:ip4_address()], task_status(), [binary()], [binary()], orddict:orddict())
    -> orddict:orddict().
vip_permutations(_IPs, _Status = #{healthy := false}, _Ports, _Labels, AccIn) ->
  AccIn;
vip_permutations(IPs, _Status, Ports, Labels, AccIn) ->
  PortList = parse_ports(Ports),
  OffsetVIPs = lists:flatmap(fun label_to_offset_vip/1, Labels),
  PortVIPs = lists:flatmap(fun ({Offset, VIP}) ->
                               case length(PortList) >= Offset + 1 of
                                 true ->
                                   Port = lists:nth(Offset + 1, PortList),
                                   [{Port, VIP}];
                                 false ->
                                   lager:warning("Could not parse VIP spec: port index ~B too high for VIP ~p",
                                                 [Offset, VIP]),
                                   []
                               end
                           end, OffsetVIPs),
  %% Although a task will pretty much always have only one IP,
  %% it's possible for the structure in mesos to have others added,
  %% and we don't want to brittle to this possible future.
  IPPortVIPPerms = [{IP, Port, VIP} || IP <- IPs, {Port, VIP} <- PortVIPs],
  lists:foldl(fun vip_collect/2, AccIn, IPPortVIPPerms).

-spec vip_collect(tuple(), orddict:orddict()) -> orddict:orddict().
vip_collect({IP, Port, VIP}, AccIn) ->
  case normalize_vip(VIP) of
    {error, _} ->
      AccIn;
    ProtoHostPort ->
      orddict:append_list(ProtoHostPort, [{IP, Port}], AccIn)
  end;
vip_collect(_, AccIn) ->
  AccIn.

vip_discovery(_IPs, _Status = #{healthy := false}, _Discovery, AccIn) ->
  AccIn;
vip_discovery(IPs, Status, _Discovery = #{ports := #{ports := Ports}}, AccIn) ->
  vip_ports(IPs, Status, Ports, AccIn).


vip_ports(_IPs, _Status, _Ports = [], AccIn) ->
  AccIn;
vip_ports(IPs, Status, _Ports = [Port = #{labels := #{labels := Labels}}|RestPorts], AccIn) ->
  Acc2 = vip_labels(IPs, Status, Port, Labels, AccIn),
  vip_ports(IPs, Status, RestPorts, Acc2);
vip_ports(IPs, Status, _Ports = [_Port|RestPorts], AccIn) ->
  vip_ports(IPs, Status, RestPorts, AccIn).


vip_labels(_IPs, _Status, _Port, _Labels = [], AccIn) ->
  AccIn;
vip_labels(IPs, Status, Port, [#{key := <<"vip", _/binary>>, value := Value}|RestLabels], AccIn) ->
  Acc2 = permute_label(IPs, Port, Value, AccIn),
  vip_labels(IPs, Status, Port, RestLabels, Acc2);
vip_labels(IPs, Status, Port, [#{key := <<"VIP", _/binary>>, value := Value}|RestLabels], AccIn) ->
  Acc2 = permute_label(IPs, Port, Value, AccIn),
  vip_labels(IPs, Status, Port, RestLabels, Acc2);
vip_labels(IPs, Status, Port, [_Label|RestLabels], AccIn) ->
  vip_labels(IPs, Status, Port, RestLabels, AccIn).

permute_label(IPs, _Port = #{protocol := ProtocolBin, number := PortNumber}, BinVIP, Acc) ->
  VIP = parse_vip(ProtocolBin, BinVIP),
  Backends = [{IP, PortNumber} || IP <- IPs],
  orddict:append_list(VIP, Backends, Acc).

parse_protocol(<<"tcp">>) ->
  tcp.

parse_vip(ProtocolBin, BinaryVIP) ->
  Protocol = parse_protocol(ProtocolBin),
  StrVIP = binary_to_list(BinaryVIP),
  [StrIP, StrPort] = string:tokens(StrVIP, ":"),
  {ok, IP} = inet:parse_ipv4_address(StrIP),
  {Port, ""} = string:to_integer(StrPort),
  {Protocol, IP, Port}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Parses labels to pull out a possible VIP mapping.
%% @end
%%--------------------------------------------------------------------
-spec label_to_offset_vip(label()) -> [tuple()].
label_to_offset_vip(#{key := <<"vip_PORT", PortNum/binary>>, value := VIP}) ->
  case string:to_integer(binary_to_list(PortNum)) of
    {Offset, []} -> [{Offset, VIP}];
    {error, E} ->
      lager:warning("Could not parse VIP port index from spec ~p: ~p", [PortNum, E]),
      [];
    _ ->
      lager:warning("Could not parse VIP port index from spec ~p", [PortNum]),
      []
  end;
label_to_offset_vip(_) ->
  [].

-spec status_to_ips(task_status()) -> [inet:ip4_address()].
status_to_ips(_Status = #{container_status := #{network_infos := NetworkInfos}}) ->
  network_info_to_ips(NetworkInfos, []);
status_to_ips(_) ->
  [].

-spec network_info_to_ips([network_info()], [inet:ip4_address()]) -> [inet:ip4_address()].
network_info_to_ips([], Acc) ->
  Acc;
network_info_to_ips([NetworkInfo|Rest], Acc) ->
  #{ip_address := IPAddressBin} = NetworkInfo,
  {ok, IPAddress} = inet:parse_ipv4_address(binary_to_list(IPAddressBin)),
  network_info_to_ips(Rest, [IPAddress|Acc]).

-spec parse_ports(binary()) -> [pos_integer()].
parse_ports(Ports) ->
  %% Denormalize the ports
  PortsStr = erlang:binary_to_list(Ports),
  PortsStr1 = string:strip(PortsStr, left, $[),
  PortsStr2 = string:strip(PortsStr1, right, $]),
  BeginEnds = string:tokens(PortsStr2, ", "),
  ListOfRangeStrs = [string:tokens(Range, "-") || Range <- BeginEnds],
  %% ASSUMPTION: small port ranges
  ListOfLists = [lists:seq(string_to_integer(Begin), string_to_integer(End))
                 || [Begin, End] <- ListOfRangeStrs],
  PortList = lists:flatten(ListOfLists),
  lists:usort(PortList).

-spec string_to_integer(string()) -> pos_integer() | error.
string_to_integer(Str) ->
  {Int, _Rest} = string:to_integer(Str),
  Int.

-spec normalize_vip(vip_string()) -> {tcp | udp, inet:ip4_address(), inet:port_number()} | {error, string()}.
normalize_vip(<<"tcp://", Rest/binary>>) ->
  parse_host_port(tcp, Rest);
normalize_vip(<<"udp://", Rest/binary>>) ->
  parse_host_port(udp, Rest);
normalize_vip(E) ->
  {error, {bad_vip_specification, E}}.

parse_host_port(Proto, Rest) ->
  RestStr = binary_to_list(Rest),
  case string:tokens(RestStr, ":") of
    [HostStr, PortStr] ->
      parse_host_port(Proto, HostStr, PortStr);
    _ ->
      {error, {bad_vip_specification, Rest}}
  end.

parse_host_port(Proto, HostStr, PortStr) ->
  case inet:parse_ipv4_address(HostStr) of
    {ok, Host} ->
      parse_host_port_2(Proto, Host, PortStr);
    {error, einval} ->
      {error, {bad_host_string, HostStr}}
  end.

parse_host_port_2(Proto, Host, PortStr) ->
  case string_to_integer(PortStr) of
    error ->
      {error, {bad_port_string, PortStr}};
    Port ->
      {Proto, Host, Port}
  end.

-ifdef(TEST).

proper_test() ->
  [] = proper:module(?MODULE).

%% TODO(tyler) make prop: remove tasks from last mesos master if it changed longer ago than the threshold
remove_old_agents_after_failover_test() ->
  {ok, DataEmpty} = file:read_file("testdata/empty.json"),
  {ok, DataFull} = file:read_file("testdata/two-healthcheck-free-vips-state.json"),
  Now = erlang:monotonic_time(seconds),
  StateFull = parse_json_to_vips(#state{}, DataFull, Now),
  StateNewMaster = parse_json_to_vips(StateFull, DataEmpty, Now),

  ReregistrationThreshold = minuteman_config:agent_reregistration_threshold(),
  Future = Now + ReregistrationThreshold,
  #state{vips = Vips} = parse_json_to_vips(StateNewMaster, DataEmpty, Future),
  Expected = [],
  ?assertEqual(Expected, Vips).


%% TODO(tyler) make prop: keep tasks from last mesos master if it just changed and is empty
cache_old_during_failover_test() ->
  {ok, DataEmpty} = file:read_file("testdata/empty.json"),
  {ok, DataFull} = file:read_file("testdata/two-healthcheck-free-vips-state.json"),
  Now = erlang:monotonic_time(seconds),
  StateFull = parse_json_to_vips(#state{}, DataFull, Now),
  StateFailover1 = parse_json_to_vips(StateFull, DataEmpty, Now + 60),
  StateFailover2 = parse_json_to_vips(StateFailover1, DataEmpty, Now + 120),
  StateFailover3 = parse_json_to_vips(StateFailover2, DataEmpty, Now + 180),
  #state{vips = Vips} = parse_json_to_vips(StateFailover3, DataEmpty, Now + 240),
  Expected = [
    {
      {tcp, {4, 3, 2, 1}, 1234},
      [
        {{33, 33, 33, 1}, 31362},
        {{33, 33, 33, 1}, 31634}]
    },
    {
      {tcp, {4, 3, 2, 2}, 1234},
      [
        {{33, 33, 33, 1}, 31290},
        {{33, 33, 33, 1}, 31215}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).

prop_valid_states_parse() ->
  ?FORALL(S, mesos_state(), parses(S)).

parses(S) ->
  {ok, _} = handle_response(#state{}, {ok, {{0, 200, 0}, 0, jsx:encode(S)}}).

mesos_state() ->
  ?LET({F, ET}, {list(p_framework()), integer(1449789489, 2549789489)}, #{
    elected_time => float(ET),
    frameworks => F,
    slaves => []
  }).

p_framework() ->
  ?LET(T, list(p_task()), #{
    tasks => T
  }).

p_task() ->
  NumPorts = random:uniform(20),
  ?LET({L, R, State, Statuses},
       {list(p_label(NumPorts)), list(p_resource(NumPorts)), p_taskstate(), list(p_statuses())},
       #{
         labels => L,
         resources => R,
         state => State,
         statuses => Statuses
       }).

p_label(NumPorts) ->
  ?LET(L, union([p_vip_label(NumPorts), p_non_vip_label()]), L).

p_vip_label(NumPorts) ->
  ?LET({Proto, PortNum, VIP},
       {p_proto(), integer(0, NumPorts), p_vip()},
       #{key => list_to_binary("vip_PORT" ++ integer_to_list(PortNum)),
         value => list_to_binary(Proto ++ "://" ++ VIP)}).

p_proto() ->
  ?LET(P, union(["tcp", "udp"]), P).

p_ip() ->
  ?LET({I1, I2, I3, I4},
       {integer(0, 255), integer(0, 255), integer(0, 255), integer(0, 255)},
       integer_to_list(I1) ++ "." ++
         integer_to_list(I2) ++ "." ++
         integer_to_list(I3) ++ "." ++
         integer_to_list(I4)).
p_vip() ->
  ?LET({IP, P},
       {p_ip(), integer(0, 65535)},
       IP ++ ":" ++ integer_to_list(P)).

p_non_vip_label() ->
  ?SUCHTHAT({K, _V}, {binary(), binary()}, not is_vip_label(K)).

is_vip_label(<<"vip_PORT", _Rest>>) ->
  true;
is_vip_label(_) ->
  false.

p_resource(NumPorts) ->
  ?LET({CPUs, Ports, Mem, Disk},
       {integer(), p_res_ports(NumPorts), integer(), integer()},
       #{
         cpus => CPUs,
         ports => Ports,
         mem => Mem,
         disk => Disk
        }).

p_res_ports(NumPorts) ->
  ?LET(Ports,
       ?SUCHTHAT(L, list(integer(0, 65535)), length(L) >= NumPorts),
       "[" ++ string:join(lists:map(fun (P) ->
                                        integer_to_list(P) ++ "-" ++ integer_to_list(P)
                                    end, Ports), ",") ++ "]").

p_statuses() ->
  ?LET(S, list(p_status()), S).

p_status() ->
  ?LET(NI, list(p_network_info()), #{
    container_status => #{
      network_infos => NI
    }
  }).

p_network_info() ->
  ?LET(IP, p_ip(), #{ip_address => IP}).

p_taskstate() ->
  ?LET(S, union([<<"TASK_RUNNING">>]), S).

basic_init_test() ->
  {ok, State} = init([]),
  State =:= orddict:new().

label_to_offset_vip_test() ->
  ?assertEqual(
     [{0, <<"tcp://1.2.3.4:5">>}],
     label_to_offset_vip(#{key => <<"vip_PORT0">>, value => <<"tcp://1.2.3.4:5">>})),
  ok.

task_fold_test() ->
  ?assertEqual([], task_fold([], [#{statuses => []}], [])),
  ?assertEqual([], task_fold([], [#{}], [])),
  ok.

status_to_ips_test() ->
  ?assertEqual([], status_to_ips(#{})),
  ?assertEqual([{1, 2, 3, 4}], status_to_ips(#{
                     container_status => #{
                       network_infos => [#{ip_address => <<"1.2.3.4">>}]
                     }
                   })),
  ok.

network_info_to_ips_test() ->
  ?assertEqual([], network_info_to_ips([], [])),
  ?assertEqual([1], network_info_to_ips([], [1])),
  ?assertException(error, {badmatch, _}, network_info_to_ips([#{ip_address => <<>>}], [])),
  ?assertException(error, {badmatch, _}, network_info_to_ips([#{ip_address => <<"1.a2">>}], [])),
  ?assertEqual([{1, 2, 3, 4}], network_info_to_ips([#{ip_address => <<"1.2.3.4">>}], [])),
  ok.

parse_ports_test() ->
  ?assertEqual([], parse_ports(<<>>)),
  ?assertEqual([1, 2], parse_ports(<<"[1-2]">>)),
  ?assertEqual([1], parse_ports(<<"[1-1]">>)),
  ?assertEqual([], parse_ports(<<"[2-1]">>)),
  ?assertEqual([1, 2], parse_ports(<<"[2-1, 1-2, 1-2]">>)),
  ?assertEqual([1, 2, 5], parse_ports(<<"[2-1, 1-2, 5-5]">>)),
  ?assertEqual([1, 2, 5], parse_ports(<<"[1-2, 5-5]">>)),
  ?assertEqual([1, 2, 5, 9, 10, 11, 12, 13, 14, 15], parse_ports(<<"[1-2, 9-15, 5-5]">>)),
  ok.

normalize_vip_test() ->
  ?assertMatch({error, _}, normalize_vip(<<>>)),
  ?assertMatch({error, _}, normalize_vip(<<"://">>)),
  ?assertMatch({error, _}, normalize_vip(<<"tcp://">>)),
  ?assertMatch({error, _}, normalize_vip(<<"tcp://1.">>)),
  ?assertMatch({error, _}, normalize_vip(<<"tcp://1.:423">>)),
  ?assertMatch({error, _}, normalize_vip(<<"1.2.3.4:5">>)),
  ok.

prop_vips_parse() ->
  ?FORALL(#{value := VIP}, p_vip_label(0), not_error(normalize_vip(VIP))).

not_error({error, _, _}) ->
  false;
not_error(_) ->
  true.

two_health_check_free_vips_test() ->
  {ok, Data} = file:read_file("testdata/two-healthcheck-free-vips-state.json"),
  Now = erlang:monotonic_time(seconds),
  #state{vips = Vips} = parse_json_to_vips(#state{}, Data, Now),
  Expected = [
    {
      {tcp, {4, 3, 2, 1}, 1234},
      [
        {{33, 33, 33, 1}, 31362},
        {{33, 33, 33, 1}, 31634}]
    },
    {
      {tcp, {4, 3, 2, 2}, 1234},
      [
        {{33, 33, 33, 1}, 31290},
        {{33, 33, 33, 1}, 31215}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).


docker_basic_test() ->
  {ok, Data} = file:read_file("testdata/docker.json"),
  Now = erlang:monotonic_time(seconds),
  #state{vips = Vips} = parse_json_to_vips(#state{}, Data, Now),
  Expected = [
    {
      {tcp, {1, 2, 3, 4}, 5000},
      [
        {{10, 0, 2, 4}, 28027}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).

di_state_test() ->
  {ok, Data} = file:read_file("testdata/state_di.json"),
  Now = erlang:monotonic_time(seconds),
  #state{vips = Vips} = parse_json_to_vips(#state{}, Data, Now),
  Expected = [
    {
      {tcp, {1, 2, 3, 4}, 8080},
      [
        {{10, 0, 2, 234}, 19426}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).


state2_test() ->
  {ok, Data} = file:read_file("testdata/state2.json"),
  Now = erlang:monotonic_time(seconds),
  #state{vips = Vips} = parse_json_to_vips(#state{}, Data, Now),
  Expected = [
    {
      {tcp, {1, 2, 3, 4}, 5000},
      [
        {{10, 10, 0, 109}, 8014}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).


bad_state_test() ->
  {ok, Data} = file:read_file("testdata/bad-state-gaal.json"),
  Now = erlang:monotonic_time(seconds),
  #state{vips = Vips} = parse_json_to_vips(#state{}, Data, Now),
  Expected = [
    {
      {tcp, {10, 22, 126, 49}, 5000},
      [
        {{10, 22, 126, 51}, 25219},
        {{10, 22, 126, 51}, 10445},
        {{10, 22, 126, 51}, 13057},
        {{10, 22, 126, 51}, 19012},
        {{10, 22, 126, 51}, 4892},
        {{10, 22, 126, 51}, 25053},
        {{10, 22, 126, 51}, 5360},
        {{10, 22, 126, 51}, 15854},
        {{10, 22, 126, 51}, 9378},
        {{10, 22, 126, 51}, 8368},
        {{10, 22, 126, 51}, 24066},
        {{10, 22, 126, 51}, 17532},
        {{10, 22, 126, 51}, 28788},
        {{10, 22, 126, 51}, 19977},
        {{10, 22, 126, 51}, 9306},
        {{10, 22, 126, 51}, 7956},
        {{10, 22, 126, 51}, 24748},
        {{10, 22, 126, 51}, 16554},
        {{10, 22, 126, 51}, 12645},
        {{10, 22, 126, 51}, 13678},
        {{10, 22, 126, 51}, 11472},
        {{10, 22, 126, 51}, 11759},
        {{10, 22, 126, 51}, 12362},
        {{10, 22, 126, 51}, 20537},
        {{10, 22, 126, 51}, 12354},
        {{10, 22, 126, 51}, 11285},
        {{10, 22, 126, 51}, 5955},
        {{10, 22, 126, 51}, 28006},
        {{10, 22, 126, 51}, 28736},
        {{10, 22, 126, 51}, 23543},
        {{10, 22, 126, 51}, 15816},
        {{10, 22, 126, 51}, 1247},
        {{10, 22, 126, 51}, 9794},
        {{10, 22, 126, 51}, 18722},
        {{10, 22, 126, 51}, 12901},
        {{10, 22, 126, 51}, 9294},
        {{10, 22, 126, 51}, 2662},
        {{10, 22, 126, 51}, 16934},
        {{10, 22, 126, 51}, 21517},
        {{10, 22, 126, 51}, 15554},
        {{10, 22, 126, 51}, 25680},
        {{10, 22, 126, 51}, 27868},
        {{10, 22, 126, 51}, 9715},
        {{10, 22, 126, 51}, 23507},
        {{10, 22, 126, 51}, 23410},
        {{10, 22, 126, 51}, 29167},
        {{10, 22, 126, 51}, 2054},
        {{10, 22, 126, 51}, 1269},
        {{10, 22, 126, 51}, 24388},
        {{10, 22, 126, 51}, 18044},
        {{10, 22, 126, 51}, 9491},
        {{10, 22, 126, 51}, 19619},
        {{10, 22, 126, 51}, 3181},
        {{10, 22, 126, 51}, 22575},
        {{10, 22, 126, 51}, 3317},
        {{10, 22, 126, 51}, 8190},
        {{10, 22, 126, 51}, 24829},
        {{10, 22, 126, 51}, 11183},
        {{10, 22, 126, 51}, 28082},
        {{10, 22, 126, 51}, 20833},
        {{10, 22, 126, 51}, 4572},
        {{10, 22, 126, 51}, 9851},
        {{10, 22, 126, 51}, 8188},
        {{10, 22, 126, 51}, 25561},
        {{10, 22, 126, 51}, 11098},
        {{10, 22, 126, 51}, 12588},
        {{10, 22, 126, 51}, 13645},
        {{10, 22, 126, 51}, 10556},
        {{10, 22, 126, 51}, 21495},
        {{10, 22, 126, 51}, 14726},
        {{10, 22, 126, 51}, 25270},
        {{10, 22, 126, 51}, 3364},
        {{10, 22, 126, 51}, 21981},
        {{10, 22, 126, 51}, 3996},
        {{10, 22, 126, 51}, 21012},
        {{10, 22, 126, 51}, 22553},
        {{10, 22, 126, 51}, 19930},
        {{10, 22, 126, 51}, 16739},
        {{10, 22, 126, 51}, 25885},
        {{10, 22, 126, 51}, 26723},
        {{10, 22, 126, 51}, 17187},
        {{10, 22, 126, 51}, 14599},
        {{10, 22, 126, 51}, 30892},
        {{10, 22, 126, 51}, 19472},
        {{10, 22, 126, 51}, 13700},
        {{10, 22, 126, 51}, 25624},
        {{10, 22, 126, 51}, 15374},
        {{10, 22, 126, 51}, 22461},
        {{10, 22, 126, 51}, 29022},
        {{10, 22, 126, 51}, 25929},
        {{10, 22, 126, 51}, 24392},
        {{10, 22, 126, 51}, 27132},
        {{10, 22, 126, 51}, 25297},
        {{10, 22, 126, 51}, 23916},
        {{10, 22, 126, 51}, 16385},
        {{10, 22, 126, 51}, 3653},
        {{10, 22, 126, 51}, 12167},
        {{10, 22, 126, 51}, 6679},
        {{10, 22, 126, 51}, 10547},
        {{10, 22, 126, 51}, 29747}
      ]
    }
  ],
  ?assertEqual(Expected, Vips).

-endif.
