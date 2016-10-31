-module(minuteman_metrics_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> [test_init,
          test_push_metrics,
          test_gen_server].


test_init(_Config) -> ok.
test_gen_server(_Config) ->
    erlang:send(minuteman_metrics, hello),
    ok = gen_server:call(minuteman_metrics, hello),
    ok = gen_server:cast(minuteman_metrics, hello),
    sys:suspend(minuteman_metrics),
    sys:change_code(minuteman_metrics, random_old_vsn, minuteman_metrics, []),
    sys:resume(minuteman_metrics).

test_push_metrics(_Config) ->
    erlang:send(ip_vs_conn_monitor, poll_proc),
    erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

proc_file(_) -> "../../../../testdata/proc_ip_vs_conn2".
init_per_testcase(Test, Config) ->
  application:set_env(ip_vs_conn, proc_file, proc_file(Test)),
  case os:cmd("id -u") of
    "0\n" ->
      ok;
    _ ->
      application:set_env(minuteman, enable_networking, false)
  end,
  {ok, _} = application:ensure_all_started(minuteman),
  Config.

end_per_testcase(_, _Config) ->
  ok = application:stop(minuteman).
