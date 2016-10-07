-module(minuteman_ct_latency_observer_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("include/minuteman.hrl").
-include_lib("telemetry/include/telemetry.hrl").

all() -> all(os:cmd("id -u")).

%% root tests
all("0\n") ->
  [test_init,
   test_named_vip_timeout];

%% non root tests
all(_) -> [].

test_init(_Config) -> ok.

test_named_vip_timeout(_Config) ->
  IP = {10, 0, 1, 31},
  Port = 12998,
  VIPPort = 6000,
  Name = <<"de8b9dc86.marathon">>,

  % inject an update for this vip
  {ok, _} = lashup_kv:request_op(?VIPS_KEY,
                                 {update, [{update, {{tcp, {name, {<<"de8b9dc86">>, <<"marathon">>}},
                                                      VIPPort}, riak_dt_orswot},
                                            {add, {IP, Port} }}]}),

  % find the assigned IP that this minuteman instance gave for this Name
  [{ip, VIP}] = minuteman_lashup_vip_listener:lookup_vips([{name, Name}]),
  ID = 100,

  % inject a timeout event
  {ok, TimerID} = timer:send_after(minuteman_config:tcp_connect_threshold(),
                                       {check_conn_connected, {ID, IP, Port, VIP, VIPPort}}),
  ets:insert(connection_timers, #ct_timer{id = ID,
                                          timer_id = TimerID,
                                          start_time = erlang:monotonic_time(nano_seconds)}),
  Msg = {check_conn_connected, {ID, IP, Port, VIP, VIPPort}},
  Msg = minuteman_ct_latency_observer ! Msg,

  % get the timeout event from telemetry and verify that its there
  timer:sleep(telemetry_config:interval_seconds()*1000),
  Metrics = telemetry_store:reap(),
  [{Item, _}|_] = Metrics#metrics.time_to_counters,
  {_, {name_tags, mm_connect_failures, Map}} = Item,
  Name = maps:get(name, Map),
  <<"11.0.0.91_6000">> = maps:get(vip, Map),
  ok.

init_per_testcase(_, Config) ->
  application:set_env(telemetry, interval_seconds, 1),
  {ok, _} = application:ensure_all_started(minuteman),
  Config.

end_per_testcase(_, _Config) ->
  ok = application:stop(minuteman).
