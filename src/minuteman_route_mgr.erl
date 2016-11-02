%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Nov 2016 9:36 AM
%%%-------------------------------------------------------------------
-module(minuteman_route_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, update_routes/2]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    netlink :: pid(),
    routes :: ordsets:ordset()
}).

-type state() :: state().
-include_lib("gen_netlink/include/netlink.hrl").
-define(MINUTEMAN_TABLE, 52).
-define(IFIDX_LO, 1).


%%%===================================================================
%%% API
%%%===================================================================

update_routes(Pid, Routes) ->
    gen_server:call(Pid, {update_routes, Routes}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

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
    {ok, Pid} = minuteman_netlink:start_link(?NETLINK_ROUTE),
    Routes = get_routes(Pid),
    ensure_fib_rule(Pid),
    {ok, #state{netlink = Pid, routes = Routes}}.

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
handle_call({update_routes, Routes}, _From, State0) ->
    State1 = handle_update_routes(Routes, State0),
    {reply, ok, State1};
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

get_routes(Pid) ->
    {ok, Raw} = minuteman_netlink:rtnl_request(Pid, getroute, [match, root], {inet, 0, 0, 0, 0, 0, 0, 0, [], []}),
    Routes0 =
        [proplists:get_value(dst, element(10, Msg)) ||
            #rtnetlink{msg = Msg} <- Raw, element(5, Msg) == ?MINUTEMAN_TABLE],
    ordsets:from_list(Routes0).

handle_update_routes(NewRoutes, State0 = #state{routes = OldRoutes}) ->
    RoutesToDelete = ordsets:subtract(OldRoutes, NewRoutes),
    RoutesToAdd = ordsets:subtract(NewRoutes, OldRoutes),
    lists:foreach(fun(Route) -> add_route(Route, State0) end, RoutesToAdd),
    lists:foreach(fun(Route) -> remove_route(Route, State0) end, RoutesToDelete),
    State0#state{routes = NewRoutes}.

add_route(Dst, #state{netlink = Pid}) ->
    Msg = [{table, ?MINUTEMAN_TABLE}, {dst, Dst}, {oif, ?IFIDX_LO}],
    Route = {
        inet,
        _PrefixLen = 32,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = ?MINUTEMAN_TABLE,
        _Protocol = boot,
        _Scope = link,
        _Type = unicast,
        _Flags = [],
        Msg},
    {ok, _} = minuteman_netlink:rtnl_request(Pid, newroute, [create, excl], Route).

remove_route(Dst, #state{netlink = Pid}) ->
    Msg = [{table, ?MINUTEMAN_TABLE}, {dst, Dst}, {oif, ?IFIDX_LO}],
    Route = {
        inet,
        _PrefixLen = 32,
        _SrcPrefixLen = 0,
        _Tos = 0,
        _Table = ?MINUTEMAN_TABLE,
        _Protocol = boot,
        _Scope = link,
        _Type = unicast,
        _Flags = [],
        Msg},
    {ok, _} = minuteman_netlink:rtnl_request(Pid, delroute, [], Route).

ensure_fib_rule(Pid) ->
    {ok, Rules} = minuteman_netlink:rtnl_request(Pid, getrule, [match, root], {inet, 0, 0, 0, 0, 0, 0, 0, [], []}),
    %% See if there is a rule that goes to table ?MINUTEMAN_TABLE
    Match = [Msg || #rtnetlink{msg = Msg} <- Rules, proplists:get_value(table, element(10, Msg)) == ?MINUTEMAN_TABLE],
    case Match of
        [] ->
            Msg = [{src, <<>>}, {priority,10000}, {table, ?MINUTEMAN_TABLE}],
            Rule = {
                inet,
                _PrefixLen = 0,
                _SrcPrefixLen = 0,
                _Tos = 0,
                _Table = ?MINUTEMAN_TABLE,
                _Protocol = unspec,
                _Scope = universe,
                _Type = unicast,
                _Flags = [],
                Msg
            },
            minuteman_netlink:rtnl_request(Pid, newrule, [create, excl], Rule);
        _ ->
            ok
    end.



