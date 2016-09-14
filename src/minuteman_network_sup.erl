%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Dec 2015 2:56 PM
%%%-------------------------------------------------------------------
-module(minuteman_network_sup).
-author("sdhillon").


-behaviour(supervisor).

-include("minuteman.hrl").
%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).


-define(RULES(Begin, End), [
  {raw, output, "-p tcp -m set --match-set minuteman dst,dst -m tcp "++
    "--tcp-flags FIN,SYN,RST,ACK SYN -j NFQUEUE --queue-balance ~B:~B", [Begin, End]},
  {raw, prerouting, "-p tcp -m set --match-set minuteman dst,dst -m tcp "++
    "--tcp-flags FIN,SYN,RST,ACK SYN -j NFQUEUE --queue-balance ~B:~B", [Begin, End]},
  {filter, output, "-p tcp -m set --match-set minuteman dst,dst -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REJECT", []},
  {filter, forward, "-p tcp -m set --match-set minuteman dst,dst -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REJECT", []}
]).

-define(MODULES, ["xt_CT","xt_LOG","xt_mark","xt_set","ip_set","xt_nat","xt_NFQUEUE",
  "xt_conntrack","xt_addrtype","xt_CHECKSUM","nf_nat","nf_conntrack",
  "xt_tcpudp","x_tables","nf_log_ipv4","nf_log_common","nf_reject_ipv4",
  "nfnetlink_log","nfnetlink_acct","nf_tables","nf_conntrack_netlink",
  "nfnetlink_queue","nfnetlink","nf_nat_masquerade_ipv4","nf_conntrack_ipv4",
  "nf_defrag_ipv4","nf_nat_ipv4","nf_nat","nf_conntrack", "iptable_nat", "ipt_MASQUERADE"]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  setup_iptables(),
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
  Children =
  [
    ?CHILD(minuteman_ct_sup, supervisor),
    ?CHILD(minuteman_iface_server, worker),
    ?CHILD(minuteman_routes, worker),
    ?CHILD(minuteman_lb, worker),
    ?CHILD(minuteman_ct_latency_observer, worker),
    ?CHILD(minuteman_worker_sup, supervisor),
    ?CHILD(minuteman_nfq_sup, supervisor)
  ],
  {ok,
    {
      {one_for_one, 5, 10},
      Children
    }
  }.

setup_iptables() ->
  lists:foreach(fun(Module) -> os:cmd(lists:flatten(io_lib:format("modprobe ~s", [Module]))) end, ?MODULES),
  {Begin, End} = minuteman_config:queue(),
  lists:foreach(fun load_rule/1, ?RULES(Begin, End)).
load_rule({Table, Chain, Rule, Args}) ->
  Rule1 = lists:flatten(io_lib:format(Rule, Args)),
  case iptables:check(Table, Chain, Rule1) of
    {ok, []} ->
      ok;
    _ ->
      lager:debug("Loading rule: ~p", [Rule1]),
      case iptables:insert(Table, Chain, Rule1) of
        {ok, _} ->
          ok;
        Else ->
          lager:error("Unknown response: ~p", [Else]),
          erlang:error(iptables_fail)
      end
  end.
