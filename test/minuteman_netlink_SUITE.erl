%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. Sep 2016 5:55 PM
%%%-------------------------------------------------------------------
-module(minuteman_netlink_SUITE).
-author("sdhillon").


-include_lib("gen_netlink/include/netlink.hrl").
-include("minuteman.hrl").

-include_lib("common_test/include/ct.hrl").

%% API
-export([all/0, enc_generic/1, getfamily/1, init_per_testcase/2, test_ipvs_mgr/1, test_route_mgr/1]).

%% root tests
all() -> [enc_generic, test_ipvs_mgr, test_route_mgr].

init_per_testcase(enc_generic, Config) ->
    Config;
init_per_testcase(TestCase, Config) ->
    Uid = list_to_integer(string:strip(os:cmd("id -u"), right, $\n)),
    init_per_testcase(Uid, TestCase, Config).

init_per_testcase(0, TestCase, Config) when TestCase == getfamily; TestCase == test_ipvs_mgr->
    case file:read_file_info("/sys/module/ip_vs") of
        {ok, _} ->
            Config;
        _ ->
            {skip, "Either not running on Linux, or ip_vs module not loaded"}
    end;
init_per_testcase(0, _TestCase, Config) ->
    Config;
init_per_testcase(_, _, _) ->
    {skip, "Not running as root"}.

enc_generic(_Config) ->
    Pid = 0,
    Seq = 0,
    Flags = [ack, request],
    Payload = #getfamily{request = [{family_name, "IPVS"}]},
    Msg = {netlink, ctrl, Flags, Seq, Pid, Payload},
    Out = netlink_codec:nl_enc(generic, Msg),
    Out = <<32, 0, 0, 0, 16, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0, 0, 9, 0, 2, 0, 73, 80, 86, 83, 0, 0, 0, 0>>.

getfamily(_Config) ->
    {ok, Pid} = gen_netlink_client:start_link(),
    {ok, _Family} = gen_netlink_client:get_family(Pid, "IPVS").

test_ipvs_mgr(_Config) ->
    %% Reset IPVS State
    {ok, Pid} = minuteman_ipvs_mgr:start_link(),
    "" = os:cmd("ipvsadm -C"),
    [] =  minuteman_ipvs_mgr:get_services(Pid),
    false = has_vip({4, 4, 4, 4}, 80),
    ok = minuteman_ipvs_mgr:add_service(Pid, {4, 4, 4, 4}, 80),
    true = has_vip({4, 4, 4, 4}, 80).


has_vip(IP, Port) ->
    Data = os:cmd("ipvsadm-save -n"),
    VIPEntry0 = io_lib:format("-A -t ~s:~B", [inet:ntoa(IP), Port]),
    VIPEntry1 = lists:flatten(VIPEntry0),
    0 =/= string:str(Data, VIPEntry1).

%has_backend(_VIP = {VIPIP, VIPPort}, _BE = {BEIP, BEPort}) ->
%    Data = os:cmd("ipvsadm-save -n"),
%    BEEntry0 = io_lib:format("-A -t ~s:~B -r ~s:~B", [inet:ntoa(VIPIP), VIPPort, inet:ntoa(BEIP), BEPort]),
%    BEEntry1 = lists:flatten(BEEntry0),
%    0 =/= string:str(Data, BEEntry1).

routes() ->
    Data = os:cmd("ip route show table 52"),
    Lines = string:tokens(Data, "\n"),
    lists:map(fun string:strip/1, Lines).

test_route_mgr(_Config) ->
    {ok, Pid} = minuteman_route_mgr:start_link(),
    minuteman_route_mgr:update_routes(Pid, [{1, 2, 3, 4}]),
    ["1.2.3.4 dev lo  scope link"] = routes(),
    minuteman_route_mgr:update_routes(Pid, []),
    [] = routes().
