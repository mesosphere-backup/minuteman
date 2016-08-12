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
  new_dst_ip,
  new_dst_port
  }).

-record(backend, {
  ip_port :: ip_port(),
  clock = fun minuteman_lb:now/0,

  % total success and failure counters
  total_successes = 0,
  total_failures = 0,

  % Number of in-flight connections.
  pending = 0,

  % current count of consecutive failures
  consecutive_failures = 0,

  % if this is crossed, back off for
  % failure_backoff ns from last_failure_time
  max_failure_threshold = minuteman_config:tcp_consecutive_failure_threshold(),
  last_failure_time = 0,
  failure_backoff =  minuteman_config:tcp_failed_backend_backoff_period() * 1.0e6
  }).

-define(SERVER_NAME_WITH_NUM(Num),
  list_to_atom(lists:flatten([?MODULE_STRING, "_", integer_to_list(Num)]))).

-type ip_port() :: {inet:ip4_address(), inet:port_number()}.
-type backend() :: #backend{}.
-type backends() :: [backend()].


%-define(LOG(Formatting, Args), lager:debug(Formatting, Args)).
-define(MM_LOG(Formatting, Args), ok).

%-define(LOG(Formatting), lager:debug(Formatting)).
-define(MM_LOG(Formatting), ok).
-define(CT_WORKERS,
[
  minuteman_ct_1,
  minuteman_ct_2,
  minuteman_ct_3,
  minuteman_ct_4,
  minuteman_ct_5,
  minuteman_ct_6,
  minuteman_ct_7,
  minuteman_ct_8
  ]
).

-define(VIPS_KEY, [minuteman, vips]).
