%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jan 2016 9:48 PM
%%%-------------------------------------------------------------------
-module(minuteman_worker_sup).
-author("sdhillon").

-behaviour(supervisor).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% API
-export([start_link/0]).


start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
  Children = [],
  {ok,
    {
      {one_for_one, 5, 10},
      Children
    }
  }.