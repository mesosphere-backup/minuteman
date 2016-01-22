%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Jan 2016 1:24 AM
%%%-------------------------------------------------------------------
-module(minuteman_ct_sup).
-author("sdhillon").

-behaviour(supervisor).

-include("minuteman.hrl").
%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).


workerid_to_childspec(WorkerID) ->
  {WorkerID, {minuteman_ct, start_link, [WorkerID]}, permanent, 5000, worker, [minuteman_ct]}.
init([]) ->
  CTWorkers = [workerid_to_childspec(WorkerID) || WorkerID <- ?CT_WORKERS],
  {ok,
    {
      {one_for_one, 5, 10},
      CTWorkers
    }
  }.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).
