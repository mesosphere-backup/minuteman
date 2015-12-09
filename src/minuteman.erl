%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 9:07 PM
%%%-------------------------------------------------------------------
-module(minuteman).
-author("sdhillon").

%% API
-export([start/0, stop/0]).

start() ->
  application:ensure_all_started(minuteman).

stop() ->
  application:stop(minuteman).