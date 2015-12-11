%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 9:00 PM
%%%-------------------------------------------------------------------
-module(minuteman_mesos_poller).
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
handle_response(_) ->
  {error, http_error}.
framework_fold(#{tasks := Tasks}, AccIn) ->
  lists:foldl(fun task_fold/2, AccIn, Tasks).

task_fold(_Task = #{statuses := []}, AccIn) ->
  AccIn;
task_fold(_Task = #{
            labels := Labels,
            resources  := #{ports := Ports},
            statuses := Statuses,
            state := <<"TASK_RUNNING">>}, AccIn) ->
  %% we only care about the most recent status, which will be the last in the list
  [Status|_] = lists:reverse(Statuses),

  %% to be compatible with mesos versions below 0.26, assume true if unspecified
  case maps:get(healthy, Status, true) of
    false ->
      AccIn;
    true ->
      IPs = status_to_ips(Status),
      PortList = parse_ports(Ports),
      OffsetVIPs = lists:flatmap(fun label_to_offset_vip/1, Labels),
      PortVIPs = lists:map(fun ({Offset, VIP}) ->
                             Port = lists:nth(Offset + 1, PortList),
                             {Port, VIP}
                           end, OffsetVIPs),
      IPPortVIPPerms = [{IP, Port, VIP} || IP <- IPs, {Port, VIP} <- PortVIPs],
      Fun = fun({IP, Port, VIP}, AccIn2) ->
              orddict:append_list(normalize_vip(VIP), [{IP, Port}], AccIn2);
              (_, AccIn2) ->
                AccIn2
            end,
      lists:foldl(Fun, AccIn, IPPortVIPPerms)
  end;
task_fold(_, AccIn) ->
  AccIn.

label_to_offset_vip(#{key := <<"vip_PORT", PortNum/binary>>, value := VIP}) ->
  Offset = list_to_integer(binary_to_list(PortNum)),
  [{Offset, VIP}];
label_to_offset_vip(_) ->
  [].

status_to_ips(_Status = #{container_status := #{network_infos := NetworkInfos}}) ->
  lists:map(fun(NetworkInfo) ->
              #{ip_address := IPAddressBin} = NetworkInfo,
              {ok, IPAddress} = inet:parse_ipv4_address(binary_to_list(IPAddressBin)),
              IPAddress
            end, NetworkInfos);
status_to_ips(_) ->
  [].

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
  lists:flatten(ListOfLists).

string_to_integer(Str) ->
  {Int, _Rest} = string:to_integer(Str),
  Int.

normalize_vip(<<"tcp://", Rest/binary>>) ->
  RestStr = binary_to_list(Rest),
  [HostStr, PortStr] = string:tokens(RestStr, ":"),
  {ok, Host} = inet:parse_ipv4_address(HostStr),
  Port = string_to_integer(PortStr),
  {tcp, Host, Port}.
