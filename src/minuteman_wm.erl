%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Jan 2016 9:53 PM
%%%-------------------------------------------------------------------
-module(minuteman_wm).
-author("sdhillon").

%% API
-export([start/0]).

dispatch() ->
  lists:flatten([
    {["metrics"], minuteman_api, []},
    {["vips"], minuteman_api, []},
    {["vip", vip], minuteman_api, []},
    {["backend", backend], minuteman_api, []},
    {["lashup", '*'], minuteman_wm_lashup, []},
    {['*'], minuteman_wm_home, []}
  ]).


start() ->
  Dispatch = dispatch(),
  ApiConfig = [
    {ip, minuteman_config:api_listen_ip()},
    {port, minuteman_config:api_listen_port()},
    {log_dir, "priv/log"},
    {dispatch, Dispatch}
  ],
  webmachine_mochiweb:start(ApiConfig).
