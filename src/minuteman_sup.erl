-module(minuteman_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================


maybe_add_network_child(Children) ->
    case minuteman_config:networking() of
        true ->
            [?CHILD(minuteman_network_sup, supervisor)|Children];
        false ->
            Children
    end.
add_default_children(Children) ->
    {ok, _App} = application:get_application(?MODULE),
    Webmachine = {minuteman_wm, {minuteman_wm, start, []},
           permanent, 5000, worker, [minuteman_wm, mochiweb_socket_server]},

    [
        Webmachine,
        ?CHILD(minuteman_vip_events, worker),
        ?CHILD(minuteman_ipsets, worker),
        ?CHILD(minuteman_vip_server, worker),
        ?CHILD(minuteman_mesos_poller, worker)|
        Children
    ].

get_children() ->
    Children1 = maybe_add_network_child([]),
    Children2 = add_default_children(Children1),
    Children2.

init([]) ->
    {ok, { {one_for_one, 5, 10}, get_children()} }.

