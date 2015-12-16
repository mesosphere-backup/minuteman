%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 12:49 AM
%%%-------------------------------------------------------------------
-module(minuteman_network_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Num), {I, {I, start_link, [Num]}, permanent, 5000, Type, [I]}).

-define(RULES, [
  {raw, output, "-p tcp -m set --match-set minuteman dst,dst -m tcp "++
    "--tcp-flags FIN,SYN,RST,ACK SYN -j NFQUEUE --queue-num QUEUE_NUMBER –-queue-bypass"},
  {raw, prerouting, "-p tcp -m set --match-set minuteman dst,dst -m tcp "++
    "--tcp-flags FIN,SYN,RST,ACK SYN -j NFQUEUE --queue-num QUEUE_NUMBER –-queue-bypass"},
  {filter, output, "-p tcp -m set --match-set minuteman dst,dst -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REJECT"},
  {filter, forward, "-p tcp -m set --match-set minuteman dst,dst -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REJECT"}
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

start_link(Num) ->
  supervisor:start_link(?MODULE, [Num]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Num]) ->
  {ok,
   { {one_for_one, 5, 10},
     [
       ?CHILD(minuteman_ct, worker, Num),
       ?CHILD(minuteman_packet_handler, worker, Num),
       ?CHILD(minuteman_nfq, worker, Num)
     ]} }.


