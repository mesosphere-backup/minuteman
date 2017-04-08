-module(minuteman_restart_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> [test_restart].

init_per_suite(Config) ->
  %% this might help, might not...
  os:cmd(os:find_executable("epmd") ++ " -daemon"),
  {ok, Hostname} = inet:gethostname(),
  case net_kernel:start([list_to_atom("runner@" ++ Hostname), shortnames]) of
    {ok, _} -> ok;
    {error, {already_started, _}} -> ok
  end,
  Config.

end_per_suite(Config) ->
  net_kernel:stop(),
  Config.

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
  ok = application:stop(minuteman),
  ok = application:stop(lashup),
  ok = application:stop(mnesia).
