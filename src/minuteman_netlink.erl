%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, Mesosphere, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 10. Oct 2016 5:16 PM
%%%-------------------------------------------------------------------
-module(minuteman_netlink).
-author("sdhillon").

-behavior(gen_statem).
-include_lib("gen_netlink/include/netlink.hrl").

-record(state, {
    port                :: port(),
    fd                  :: non_neg_integer(),
    pid                 :: non_neg_integer(),
    seq = 0             :: non_neg_integer(),
    last_rq_from        :: undefined | gen_statem:from(),
    replies = []        :: list(),
    current_seq         :: undefined | non_neg_integer(),
    family
}).

-type state_data() :: #state{}.

-type state_name() :: idle | wait_for_responses.

%% API
-export([start_link/0, start_link/1]).
-export([request/5, request/4, get_family/2, rtnl_request/3, rtnl_request/4]).

%% gen_statem behaviour
-export([init/1, terminate/3, code_change/4, callback_mode/0]).

%% State callbacks
-export([idle/3, wait_for_responses/3, wait_for_responses_rtnl/3]).

-record(request, {family, cmd, flags, msg}).
-record(rtnl_request, {type, flags, msg}).

-type response_message() :: term().
-type response_messages() :: [response_message()].

-type request_reply() :: {ok, response_messages()} | {error, ErrorCode :: non_neg_integer(), response_messages()}.
%% family() is taken by some stuff in gen_netlink
-type family2() :: non_neg_integer() | {generic, Id :: non_neg_integer(), Name :: atom()}.

-spec(request(Pid :: pid(), Family :: family2(), Command :: atom(), Msg :: term()) -> request_reply()).
request(Pid, Family, Command, Msg) ->
    request(Pid, Family, Command, [], Msg).
request(Pid, Family, Command, Flags, Msg) ->
    gen_statem:call(Pid, #request{family = Family, cmd = Command, flags = Flags, msg = Msg}, 5000).


-spec(rtnl_request(Pid :: pid(), Type :: atom(), Msg :: term()) -> request_reply()).
rtnl_request(Pid, Type, Msg) ->
    rtnl_request(Pid, Type, [], Msg).
rtnl_request(Pid, Type, Flags, Msg) ->
    gen_statem:call(Pid, #rtnl_request{type = Type, flags = Flags, msg = Msg}, 5000).

-spec(get_family(Pid :: pid(), FamilyName :: string()) -> error | {ok, family2()}).
get_family(Pid, FamilyName) ->
    Request = [{family_name, FamilyName}],
    case request(Pid, ?NETLINK_GENERIC, ctrl, #getfamily{request = Request}) of
        {error, _, _} ->
            error;
        {ok, [#netlink{msg = #newfamily{request = Response}}]} ->
            {family_id, Id} = proplists:lookup(family_id, Response),
            Family = {generic, Id, family_name_to_friendly(FamilyName)},
            {ok, Family}
    end.

family_name_to_friendly("IPVS") ->
    ipvs.

start_link() ->
    gen_statem:start_link(?MODULE, [?NETLINK_GENERIC], []).

start_link(FamilyID) ->
    gen_statem:start_link(?MODULE, [FamilyID], []).

-spec(init([FamilyID :: non_neg_integer()]) -> {ok, state_name(), state_data()}).
init([FamilyID]) ->
    Pid = list_to_integer(os:getpid()),
    {ok, Fd} = procket:socket(netlink, dgram, FamilyID),
    Port = erlang:open_port({fd, Fd, Fd}, [binary]),
    spawn_watch(Port, Fd),
    State = #state{fd = Fd, port = Port, pid = Pid, family = FamilyID},
    {ok, idle, State}.


idle({call, From}, #rtnl_request{type = Type, flags = Flags0, msg = Msg},
    State0 = #state{port = Port, pid = Pid, seq = Seq0, family = Family}) ->
    Flags1 = lists:usort([request, ack] ++ Flags0),
    Seq1 = Seq0 + 1,
    NLMsg = #rtnetlink{type = Type, flags = Flags1, seq = Seq0, pid = Pid, msg = Msg},
    Out = netlink_codec:nl_enc(family_id(Family), NLMsg),
    erlang:port_command(Port, Out),
    State1 = State0#state{seq = Seq1, last_rq_from = From, replies = [], current_seq = Seq0},
    {next_state, wait_for_responses_rtnl, State1};

idle({call, From}, #request{family = Family, cmd = Command, flags = Flags0, msg = Msg},
        State0 = #state{port = Port, pid = Pid, seq = Seq0}) ->
    Flags1 = lists:usort([ack, request] ++ Flags0),
    Seq1 = Seq0 + 1,
    NLMsg = {netlink, Command, Flags1, Seq0, Pid, Msg},
    Out = netlink_codec:nl_enc(family_id(Family), NLMsg),
    erlang:port_command(Port, Out),
    State1 = State0#state{seq = Seq1, family = Family, last_rq_from = From, replies = [], current_seq = Seq0},
    {next_state, wait_for_responses, State1}.

wait_for_responses(info, {Port, {data, Data}}, #state{port = Port, family = Family}) ->
    Decoded = netlink_codec:nl_dec(family_name(Family), Data),
    NextEvents = lists:map(fun(M) -> {next_event, internal, {nl_msg, M}} end, Decoded),
    {keep_state_and_data, NextEvents};

wait_for_responses(internal, {nl_msg, Msg = #netlink{type = Type, seq = CurrentSeq}},
        State0 = #state{current_seq = CurrentSeq}) when Type == done; Type ==  error ->
    do_reply(Msg, State0),
    State1 = State0#state{last_rq_from = undefined, replies = [], current_seq = undefined},
    {next_state, idle, State1};
wait_for_responses(internal, {nl_msg, Msg = #netlink{seq = CurrentSeq}},
        State0 = #state{current_seq = CurrentSeq, replies = Replies0}) ->
    State1 = State0#state{replies = [Msg|Replies0]},
    {keep_state, State1}.

% minuteman_netlink:wait_for_responses_rtnl(internal, {nl_msg,{netlink,error,[],0,2253731618,


wait_for_responses_rtnl(info, {Port, {data, Data}}, #state{port = Port, family = Family}) ->
    Decoded = netlink_codec:nl_dec(family_name(Family), Data),
    NextEvents0 = lists:map(fun(M) -> {next_event, internal, {nl_msg, M}} end, Decoded),
    lager:debug("Decoded: ~p", [Decoded]),
    {keep_state_and_data, NextEvents0};
wait_for_responses_rtnl(internal, {nl_msg, Msg = #rtnetlink{type = Type, seq = CurrentSeq}},
    State0 = #state{current_seq = CurrentSeq}) when Type == done; Type == error ->
    do_reply(Msg, State0),
    State1 = State0#state{last_rq_from = undefined, replies = [], current_seq = undefined},
    {next_state, idle, State1};
wait_for_responses_rtnl(internal, {nl_msg, Msg = #netlink{type = Type, seq = CurrentSeq}},
    State0 = #state{current_seq = CurrentSeq}) when Type == done; Type == error ->
    do_reply(Msg, State0),
    State1 = State0#state{last_rq_from = undefined, replies = [], current_seq = undefined},
    {next_state, idle, State1};
wait_for_responses_rtnl(internal, {nl_msg, Msg = #rtnetlink{seq = CurrentSeq}},
    State0 = #state{current_seq = CurrentSeq, replies = Replies0}) ->
    State1 = State0#state{replies = [Msg|Replies0]},
    {keep_state, State1}.


do_reply(_, #state{last_rq_from = From}) when not is_pid(From) ->
    throw(inconsistent_state);
do_reply(#netlink{type = done}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {ok, Replies1});
do_reply(#netlink{type = error, msg = {_Error = 0, _Payload}}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {ok, Replies1});
do_reply(#netlink{type = error, msg = {Error, _Payload}}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {error, Error, Replies1});
do_reply(#rtnetlink{type = done}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {ok, Replies1}).




%idle({call, _From}, _EventContent, _Data) ->
%
%idle(_EventType, _EventContent, _Data) ->

%% Returns ID, if generic family
family_id({generic, Id, _Name}) ->
    Id;
family_id(Family) when is_integer(Family) ->
    Family.

family_name({generic, _Id, Name}) ->
    Name;
family_name(Family) ->
    Family.

terminate(Reason, State, Data) ->
    lager:warning("Terminating, due to: ~p, in state: ~p, with state data: ~p", [Reason, State, Data]).

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

spawn_watch(Port, Fd) ->
    spawn(fun() -> watch(Port, Fd) end).

watch(Port, Fd) ->
    MonitorRef = monitor(port, Port),
    watch_loop(Port, Fd, MonitorRef).

watch_loop(Port, Fd, MonitorRef) ->
    receive
        {_, MonitorRef, _, _, _} ->
            procket:close(Fd);
        _ ->
            watch_loop(Port, Fd, MonitorRef)
    end.

callback_mode() ->
    state_functions.
