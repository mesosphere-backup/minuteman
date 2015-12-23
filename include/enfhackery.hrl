%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:43 AM
%%%-------------------------------------------------------------------
-author("sdhillon").
-author("Tyler Neely").

-record(mapping, {
  orig_src_ip,
  orig_src_port,
  orig_dst_ip,
  orig_dst_port,
  new_src_ip,
  new_src_port,
  new_dst_ip,
  new_dst_port
  }).

-record(backend_tracking, {
  % current count of consecutive failures
  consecutive_failures = 0,

  % if this is crossed, back off for
  % failure_backoff ns from last_failure_time
  max_failure_threshold = minuteman_config:tcp_consecutive_failure_threshold(),
  last_failure_time = 0,
  failure_backoff =  minuteman_config:tcp_failed_backend_backoff_period() * 1.0e6
  }).

-record(ewma, {
  % Current value of the exponentially weighted moving average.
  cost = 0,

  % Used to measure the length of the exponential sliding window.
  stamp = erlang:monotonic_time(),

  % A large number for penalizing new backends, to ease up rates slowly.
  penalty = 1.0e307,

  % Number of in-flight measurements.
  pending = 0,

  % 10 seconds in nanoseconds.
  decay = 10.0e9
  }).

-record(backend, {
  ip_port,
  clock = fun os:system_time/0,
  tracking = #backend_tracking{},
  ewma = #ewma{}
  }).

-define(SERVER_NAME_WITH_NUM(Num),
  list_to_atom(lists:flatten([?MODULE_STRING, "_", integer_to_list(Num)]))).
