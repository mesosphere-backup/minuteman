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
-export([all/0, enc_generic/1, getfamily/1, init_per_testcase/2]).

all() ->
    [enc_generic, getfamily].

init_per_testcase(enc_generic, Config) ->
    Config;
init_per_testcase(_TestCase, Config) ->
    case file:read_file_info("/sys/module/ip_vs") of
        {ok, _} ->
            Config;
        _ ->
            {skip, "Either not running on Linux, or ip_vs module not loaded"}
    end.

enc_generic(_Config) ->
    Pid = 0,
    Seq = 0,
    Flags = [ack, request],
    Payload = #getfamily{request = [{family_name, "IPVS"}]},
    Msg = {netlink, ctrl, Flags, Seq, Pid, Payload},
    Out = netlink_codec:nl_enc(generic, Msg),
    Out = <<32, 0, 0, 0, 16, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0, 0, 9, 0, 2, 0, 73, 80, 86, 83, 0, 0, 0, 0>>.

getfamily(_Config) ->
    {ok, Pid} = minuteman_netlink:start_link(),
    {ok, _Family} = minuteman_netlink:get_family(Pid, "IPVS").