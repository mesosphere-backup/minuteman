%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Dec 2015 2:56 PM
%%%-------------------------------------------------------------------
-module(minuteman_network_sup).
-author("sdhillon").


-behaviour(supervisor).

-include("minuteman.hrl").
%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
  Children =
  [
      ?CHILD(minuteman_ipvs, worker),
      ?CHILD(minuteman_lashup_vip_listener, worker)
  ],
  {ok,
    {
      {rest_for_one, 5, 10},
      Children
    }
  }.

