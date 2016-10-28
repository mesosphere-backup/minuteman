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

get_children() ->
    [
        ?CHILD(minuteman_network_sup, supervisor),
        ?CHILD(minuteman_mesos_poller, worker),
        ?CHILD(minuteman_lashup_publish, worker),
        ?CHILD(minuteman_lashup_index, worker)
    ].

init([]) ->
    {ok, { {one_for_one, 5, 10}, get_children()} }.

