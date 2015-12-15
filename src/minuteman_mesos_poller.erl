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

-record(state, {vips = orddict:new()}).


%% Debug
-export([poll/0]).
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
  Vips = case poll() of
    {error, Reason} ->
      lager:warning("Could not poll: ~p", [Reason]),
      State#state.vips;
    {ok, NewVips} ->
      NewVips
  end,
  {noreply, State#state{vips = Vips}};
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

poll() ->
  lager:debug("Starting poll cycle"),
  {ok, _} = timer:send_after(minuteman_config:poll_interval(), poll),
  MasterURI = minuteman_config:master_uri(),
  Response = httpc:request(get, {MasterURI, []}, [], [{body_format, binary}]),
  case handle_response(Response) of
    {ok, Vips} ->
      %% I could probably use a gen_event, but where is the fun in that?
      minuteman_ipsets:push_vips(Vips),
      minuteman_vip_server:push_vips(Vips),
      {ok, Vips};
    Other ->
      Other
  end.

handle_response({ok, {{_HttpVersion, 200, _ReasonPhrase}, _Headers, Body}}) ->
  Data = jsx:decode(Body, [return_maps, {labels, atom}]),
  #{frameworks := Frameworks} = Data,
  Vips = lists:foldl(fun framework_fold/2, orddict:new(), Frameworks),
  {ok, Vips};
handle_response(Response) ->
  lager:debug("Bad HTTP Response: ~p", [Response]),
  {error, http_error}.
framework_fold(#{tasks := Tasks}, AccIn) ->
  lists:foldl(fun task_fold/2, AccIn, Tasks);
framework_fold(_, AccIn) ->
  AccIn.

-spec task_fold(map(), orddict:orddict()) -> orddict:orddict().
task_fold(_Task = #{statuses := []}, AccIn) ->
  AccIn;
task_fold(_Task = #{
            labels := Labels,
            resources  := #{ports := Ports},
            statuses := Statuses,
            state := <<"TASK_RUNNING">>}, AccIn) ->
  %% we only care about the most recent status, which will be the last in the list
  [Status|_] = lists:reverse(Statuses),
  vip_permutations(Status, Ports, Labels, AccIn);
task_fold(_, AccIn) ->
  AccIn.

-spec vip_permutations(map(), [binary()], [binary()], orddict:orddict()) -> orddict:orddict().
vip_permutations(_Status = #{healthy := false}, _Ports, _Labels, AccIn) ->
  AccIn;
vip_permutations(Status, Ports, Labels, AccIn) ->
  IPs = status_to_ips(Status),
  PortList = parse_ports(Ports),
  OffsetVIPs = lists:flatmap(fun label_to_offset_vip/1, Labels),
  PortVIPs = lists:map(fun ({Offset, VIP}) ->
                         Port = lists:nth(Offset + 1, PortList),
                         {Port, VIP}
                       end, OffsetVIPs),
  IPPortVIPPerms = [{IP, Port, VIP} || IP <- IPs, {Port, VIP} <- PortVIPs],
  lists:foldl(fun vip_collect/2, AccIn, IPPortVIPPerms).

-spec vip_collect(tuple(), orddict:orddict()) -> orddict:orddict().
vip_collect({IP, Port, VIP}, AccIn) ->
  orddict:append_list(normalize_vip(VIP), [{IP, Port}], AccIn);
vip_collect(_, AccIn) ->
  AccIn.

-spec label_to_offset_vip(map()) -> [tuple()].
label_to_offset_vip(#{key := <<"vip_PORT", PortNum/binary>>, value := VIP}) ->
  {Offset, _} =  string:to_integer(binary_to_list(PortNum)),
  [{Offset, VIP}];
label_to_offset_vip(_) ->
  [].

-spec status_to_ips(map()) -> [pos_integer()].
status_to_ips(_Status = #{container_status := #{network_infos := NetworkInfos}}) ->
  networkinfos_to_ips(NetworkInfos, []);
status_to_ips(_) ->
  [].

-spec networkinfos_to_ips([], []) -> [];
                         ([], [pos_integer()]) -> [pos_integer()];
                         ([map()], []) -> [pos_integer()].
networkinfos_to_ips([], Acc) ->
  Acc;
networkinfos_to_ips([NetworkInfo|Rest], Acc) ->
  #{ip_address := IPAddressBin} = NetworkInfo,
  {ok, IPAddress} = inet:parse_ipv4_address(binary_to_list(IPAddressBin)),
  networkinfos_to_ips(Rest, [IPAddress|Acc]).

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
  lists:usort(lists:flatten(ListOfLists)).

-spec string_to_integer(string()) -> pos_integer() | error.
string_to_integer(Str) ->
  {Int, _Rest} = string:to_integer(Str),
  Int.

-type vip_string() :: <<_:48, _:_*1>>.
-spec normalize_vip(vip_string()) -> {tcp, inet:ip_address(), inet:port_number()};
                   (vip_string()) -> {udp, inet:ip_address(), inet:port_number()};
                   (vip_string()) -> {error, string()}.
normalize_vip(<<"tcp://", Rest/binary>>) ->
  parse_host_port(tcp, Rest);
normalize_vip(<<"udp://", Rest/binary>>) ->
  parse_host_port(udp, Rest);
normalize_vip(E) ->
  {error, "bad VIP specification: " ++ E}.

parse_host_port(Proto, Rest) ->
  RestStr = binary_to_list(Rest),
  case string:tokens(RestStr, ":") of
    [HostStr, PortStr] ->
      parse_host_port_2(Proto, HostStr, PortStr);
    _ ->
      {error, "bad VIP specification: " ++ Rest}
  end.

parse_host_port_2(Proto, HostStr, PortStr) ->
  case inet:parse_ipv4_address(HostStr) of
    {ok, Host} ->
      parse_host_port_3(Proto, Host, PortStr);
    {error, einval} ->
      {error, "Bad host string: " ++ HostStr}
  end.

parse_host_port_3(Proto, Host, PortStr) ->
  case string_to_integer(PortStr) of
    error ->
      {error, "Bad port string: " ++ PortStr};
    Port ->
      {Proto, Host, Port}
  end.

-ifdef(TEST).

proper_test() ->
  [] = proper:module(?MODULE).

prop_valid_states_parse() ->
  ?FORALL(S, mesos_state(), parses(S)).

parses(S) ->
  {ok, VIPs} = handle_response({ok, {{0, 200, 0}, 0, jsx:encode(S)}}).

mesos_state() ->
  ?LET(F, list(framework()), #{
    frameworks => F
  }).

framework() ->
  ?LET(T, list(task()), #{
    tasks => T
  }).

task() ->
  NumPorts = random:uniform(20),
  ?LET({L, R, State, Statuses},
       {list(label(NumPorts)), list(resource(NumPorts)), taskstate(), list(statuses())},
       #{
         labels => L,
         resources => R,
         state => State,
         statuses => Statuses
       }).

label(NumPorts) ->
  ?LET(L, union([vip_label(NumPorts), non_vip_label()]), L).

vip_label(NumPorts) ->
  ?LET({Proto, PortNum, VIP},
       {proto(), integer(0, NumPorts), vip()},
       #{key => list_to_binary("vip_PORT" ++ integer_to_list(PortNum)),
         value => list_to_binary(Proto ++ "://" ++ VIP)}).

proto() ->
  ?LET(P, union(["tcp", "udp"]), P).

ip() ->
  measure(thing, 1, thing2),
  ?LET({I1, I2, I3, I4},
       {integer(0, 255), integer(0, 255), integer(0, 255), integer(0, 255)},
       integer_to_list(I1) ++ "." ++
         integer_to_list(I2) ++ "." ++
         integer_to_list(I3) ++ "." ++
         integer_to_list(I4)).
vip() ->
  ?LET({IP, P},
       {ip(), integer(0, 65535)},
       IP ++ ":" ++ integer_to_list(P)).

non_vip_label() ->
  ?SUCHTHAT({K, _V}, {binary(), binary()}, not is_vip_label(K)).

is_vip_label(<<"vip_PORT", _Rest>>) ->
  true;
is_vip_label(_) ->
  false.

resource(NumPorts) ->
  ?LET({CPUs, Ports, Mem, Disk},
       {integer(), res_ports(NumPorts), integer(), integer()},
       #{
         cpus => CPUs,
         ports => Ports,
         mem => Mem,
         disk => Disk
        }).

res_ports(NumPorts) ->
  ?LET(Ports,
       ?SUCHTHAT(L, list(integer(0, 65535)), length(L) >= NumPorts),
       "[" ++ string:join(lists:map(fun (P) ->
                                        integer_to_list(P) ++ "-" ++ integer_to_list(P)
                                    end, Ports), ",") ++ "]").

statuses() ->
  ?LET(S, list(status()), S).

status() ->
  ?LET(NI, list(networkinfo()), #{
    container_status => #{
      network_infos => NI
    }
  }).

networkinfo() ->
  ?LET(IP, ip(), #{ip_address => IP}).

taskstate() ->
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
  ?assertEqual([], task_fold(#{statuses => []}, [])),
  ?assertEqual([], task_fold(#{}, [])),
  ok.

status_to_ips_test() ->
  ?assertEqual([], status_to_ips(#{})),
  ?assertEqual([{1, 2, 3, 4}], status_to_ips(#{
                     container_status => #{
                       network_infos => [#{ip_address => <<"1.2.3.4">>}]
                     }
                   })),
  ok.

networkinfos_to_ips_test() ->
  ?assertEqual([], networkinfos_to_ips([], [])),
  ?assertEqual([1], networkinfos_to_ips([], [1])),
  ?assertException(error, {badmatch, _}, networkinfos_to_ips([#{ip_address => <<>>}], [])),
  ?assertException(error, {badmatch, _}, networkinfos_to_ips([#{ip_address => <<"1.a2">>}], [])),
  ?assertEqual([{1, 2, 3, 4}], networkinfos_to_ips([#{ip_address => <<"1.2.3.4">>}], [])),
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
  ok.

prop_vips_parse() ->
  ?FORALL(#{value := VIP}, vip_label(0), not_error(normalize_vip(VIP))).

not_error({error, _, _}) ->
  false;
not_error(_) ->
  true.

-endif.
