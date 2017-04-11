-module(minuteman_lb_mgr_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> [test_normalize].

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

test_normalize(Config) ->
      PrivateDir = ?config(priv_dir, Config),
      application:set_env(minuteman, agent_dets_basedir, PrivateDir),
      case os:cmd("id -u") of
        "0\n" ->
          ok;
        _ ->
          application:set_env(minuteman, enable_networking, false)
      end,
      {ok, _} = application:ensure_all_started(minuteman),
    Normalized = minuteman_lb_mgr:normalize_services_and_dests({[{address_family, 2},
      {protocol, 6},
      {address, <<11, 197, 245, 133, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
      {port, 9042},
      {sched_name, "wlc"},
      {flags, 2, 4294967295},
      {timeout, 0},
      {netmask, 4294967295},
      {stats, [{conns, 0},
              {inpkts, 0},
              {outpkts, 0},
              {inbytes, 0},
              {outbytes, 0},
              {cps, 0},
              {inpps, 0},
              {outpps, 0},
              {inbps, 0},
              {outbps, 0}]}],
     [[{address, <<10, 10, 0, 83, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
       {port, 9042},
       {fwd_method, 0},
       {weight, 1},
       {u_threshold, 0},
       {l_threshold, 0},
       {active_conns, 0},
       {inact_conns, 0},
       {persist_conns, 0},
       {stats, [{conns, 0},
               {inpkts, 0},
               {outpkts, 0},
               {inbytes, 0},
               {outbytes, 0},
               {cps, 0},
               {inpps, 0},
               {outpps, 0},
               {inbps, 0},
               {outbps, 0}]}],
      [{address, <<10, 10, 0, 248, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
       {port, 9042},
       {fwd_method, 0},
       {weight, 1},
       {u_threshold, 0},
       {l_threshold, 0},
       {active_conns, 0},
       {inact_conns, 0},
       {persist_conns, 0},
       {stats, [{conns, 0},
               {inpkts, 0},
               {outpkts, 0},
               {inbytes, 0},
               {outbytes, 0},
               {cps, 0},
               {inpps, 0},
               {outpps, 0},
               {inbps, 0},
               {outbps, 0}]}],
      [{address, <<10, 10, 0, 253, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
       {port, 9042},
       {fwd_method, 0},
       {weight, 1},
       {u_threshold, 0},
       {l_threshold, 0},
       {active_conns, 0},
       {inact_conns, 0},
       {persist_conns, 0},
       {stats, [{conns, 0},
               {inpkts, 0},
               {outpkts, 0},
               {inbytes, 0},
               {outbytes, 0},
               {cps, 0},
               {inpps, 0},
               {outpps, 0},
               {inbps, 0},
               {outbps, 0}]}]]}),
    Normalized = {{tcp, {11, 197, 245, 133}, 9042},
                  [{{10, 10, 0, 83}, 9042},
                   {{10, 10, 0, 248}, 9042},
                   {{10, 10, 0, 253}, 9042}]},
    ok = application:stop(minuteman),
    ok = application:stop(lashup),
    ok = application:stop(mnesia).
