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
    last_rq_from        :: pid() | undefined,
    replies             :: list(),
    current_seq         :: non_neg_integer(),
    family
}).

-type state_data() :: #state{}.

-type state_name() :: idle.

%% API
-export([start_link/0]).
-export([request/5, request/4, get_family/2]).

%% gen_statem behaviour
-export([init/1, terminate/3, code_change/4, callback_mode/0]).

%% State callbacks
-export([idle/3, wait_for_responses/3]).

-record(request, {family, cmd, flags, msg}).

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
    gen_statem:start_link(?MODULE, [], []).

-spec(init([]) -> {ok, state_name(), state_data()}).
init([]) ->
    Pid = list_to_integer(os:getpid()),
    {ok, Fd} = procket:socket(netlink, dgram, ?NETLINK_GENERIC),
    Port = erlang:open_port({fd, Fd, Fd}, [binary]),
    spawn_watch(Port, Fd),
    State = #state{fd = Fd, port = Port, pid = Pid},
    {ok, idle, State}.

idle({call, From}, #request{family = Family, cmd = Command, flags = Flags0, msg = Msg},
        State0 = #state{port = Port, pid = Pid, seq = Seq0}) ->
    Flags1 = lists:usort([ack, request|Flags0]),
    Seq1 = Seq0 + 1,
    NLMsg = {netlink, Command, Flags1, Seq0, Pid, Msg},
    io:format("enc(~p, ~p)~n", [family_id(Family), NLMsg]),
    Out = netlink_codec:nl_enc(family_id(Family), NLMsg),
    erlang:port_command(Port, Out),
    State1 = State0#state{seq = Seq1, family = Family, last_rq_from = From, replies = [], current_seq = Seq0},
    {next_state, wait_for_responses, State1}.

wait_for_responses(info, {Port, {data, Data}}, #state{port = Port, family = Family}) ->
    Decoded = netlink_codec:nl_dec(family_name(Family), Data),
    NextEvents = lists:map(fun(M) -> {next_event, internal, {nl_msg, M}} end, Decoded),
    {keep_state_and_data, NextEvents};

wait_for_responses(internal, {nl_msg, Msg = #netlink{type = error, seq = CurrentSeq, msg = {_Error, _Payload}}},
        State0 = #state{current_seq = CurrentSeq}) ->
    do_reply(Msg, State0),
    State1 = State0#state{last_rq_from = undefined, replies = [], current_seq = undefined},
    {next_state, idle, State1};
wait_for_responses(internal, {nl_msg, Msg = #netlink{seq = CurrentSeq}},
        State0 = #state{current_seq = CurrentSeq, replies = Replies0}) ->
    io:format("Decoded: ~p~n", [Msg]),
    State1 = State0#state{replies = [Msg|Replies0]},
    {keep_state, State1}.

do_reply(#netlink{type = error, msg = {_Error = 0, _Payload}}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {ok, Replies1});
do_reply(#netlink{type = error, msg = {Error, _Payload}}, #state{last_rq_from = From, replies = Replies0}) ->
    Replies1 = lists:reverse(Replies0),
    gen_statem:reply(From, {error, Error, Replies1}).



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
