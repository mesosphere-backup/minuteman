%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 12:49 AM
%%%-------------------------------------------------------------------
-module(minuteman_nfq_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Num), {I, {I, start_link, [Num]}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link(?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

queue_to_childspec(QueueNum) ->
  StringName = lists:flatten(io_lib:format("minuteman_nfq_~B", [QueueNum])),
  AtomName = list_to_atom(StringName),
  #{
    id => AtomName,
    start => {minuteman_nfq, start_link, [QueueNum]},
    restart => permanent,
    shutdown => 5000
  }.
init([]) ->
  {Begin, End} = minuteman_config:queue(),
  Children = [queue_to_childspec(Num) || Num <- lists:seq(Begin, End)],
  {ok,
    {
      {one_for_one, 5, 10},
      Children
    }
  }.


