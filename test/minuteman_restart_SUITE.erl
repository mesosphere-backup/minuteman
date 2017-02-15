-module(minuteman_restart_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> [test_restart].


test_restart(Config) ->
  PrivateDir = ?config(priv_dir, Config),
  application:set_env(minuteman, agent_dets_basedir, PrivateDir),
  case os:cmd("id -u") of
    "0\n" ->
      ok;
    _ ->
      application:set_env(minuteman, enable_networking, false)
  end,
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman),
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman),
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman).
