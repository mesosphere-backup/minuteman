-module(minuteman_metrics_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("minuteman.hrl").

all() -> [test_init,
          test_reorder,
          test_push_metrics,
          test_named_vip,
          test_wait_metrics,
          test_new_data,
          test_one_conn,
          test_gen_server].


test_init(_Config) -> ok.
test_gen_server(_Config) ->
    hello = erlang:send(minuteman_metrics, hello),
    ok = gen_server:call(minuteman_metrics, hello),
    ok = gen_server:cast(minuteman_metrics, hello),
    sys:suspend(minuteman_metrics),
    sys:change_code(minuteman_metrics, random_old_vsn, minuteman_metrics, []),
    sys:resume(minuteman_metrics).

test_push_metrics(_Config) ->
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_wait_metrics(_Config) ->
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_new_data(_Config) ->
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped1 ~p", [R]),
    ProcFile = "../../../../testdata/proc_ip_vs_conn3",
    application:set_env(ip_vs_conn, proc_file, ProcFile),
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(1000),
    R2 = telemetry_store:reap(),
    ct:pal("reaped2 ~p", [R2]),
    ok.

test_reorder(_Config) ->
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_one_conn(_Config) ->
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(1000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

test_named_vip(_Config) ->
    {ok, _} = lashup_kv:request_op(?VIPS_KEY, {update, [{update,
                                                       {{tcp, {name, {<<"de8b9dc86">>, <<"marathon">>}}, 8080},
                                                        riak_dt_orswot},
                                                       {add, {{10, 0, 79, 182}, 8080}}}]}),
    [{ip, IP}] = minuteman_lashup_vip_listener:lookup_vips([{name, <<"de8b9dc86.marathon">>}]),
    ct:pal("change the testdata if it doesn't match ip: ~p", [IP]),
    push_metrics = erlang:send(minuteman_metrics, push_metrics),
    timer:sleep(2000),
    R = telemetry_store:reap(),
    ct:pal("reaped ~p", [R]),
    ok.

proc_file(test_one_conn) -> "../../../../testdata/proc_ip_vs_conn1";
proc_file(_) -> "../../../../testdata/proc_ip_vs_conn2".

set_interval(test_wait_metrics) ->
    application:set_env(minuteman, metrics_interval_seconds, 1),
    application:set_env(minuteman, metrics_splay_seconds, 1);
set_interval(_) -> ok.

init_per_testcase(Test, Config) ->
  application:set_env(ip_vs_conn, proc_file, proc_file(Test)),
  case os:cmd("id -u") of
    "0\n" ->
      ok;
    _ ->
      application:set_env(minuteman, enable_networking, false)
  end,
  set_interval(Test),
  {ok, _} = application:ensure_all_started(minuteman),
  Config.

end_per_testcase(_, _Config) ->
  ok = application:stop(minuteman).
