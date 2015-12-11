%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 8:58 PM
%%%-------------------------------------------------------------------
-module(minuteman_config).
-author("sdhillon").

%% API
-export([master_uri/0, poll_interval/0, queue/0, networking/0]).


master_uri() ->
  application:get_env(minuteman, master_uri, "http://localhost:5050/state.json").


poll_interval() ->
  application:get_env(minuteman, poll_interval, 5000).

%% Returns a integer
queue() ->
  application:get_env(minuteman, queue, 0).

networking() ->
  application:get_env(minuteman, enable_networking, true).