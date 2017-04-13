%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 22. Oct 2016 9:37 PM
%%%-------------------------------------------------------------------
-module(minuteman_ipvs_SUITE).
-author("sdhillon").

-include_lib("common_test/include/ct.hrl").
-include("minuteman.hrl").

%% These tests rely on some commands that circle ci does automatically
%% Look at circle.yml for more
-export([all/0]).

-export([test_basic/1]).

-export([init_per_testcase/2, end_per_testcase/2]).

all() -> all(os:cmd("id -u"), os:getenv("CIRCLECI")).

-compile(export_all).

%% root tests
all("0\n", false) ->
    [test_basic];

%% non root tests
all(_, _) -> [].

init_per_testcase(_, Config) ->
    "" = os:cmd("ipvsadm -C"),
    os:cmd("ip link del minuteman"),
    os:cmd("ip link add minuteman type dummy"),
    os:cmd("ip link del webserver"),
    os:cmd("ip link add webserver type dummy"),
    os:cmd("ip link set webserver up"),
    os:cmd("ip addr add 1.1.1.1/32 dev webserver"),
    os:cmd("ip addr add 1.1.1.2/32 dev webserver"),
    os:cmd("ip addr add 1.1.1.3/32 dev webserver"),
    application:set_env(minuteman, agent_polling_enabled, false),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(minuteman),
    Config.

end_per_testcase(_, _Config) ->
    ok = application:stop(minuteman),
    ok = application:stop(lashup),
    ok = application:stop(mnesia).

make_webserver(Idx) ->
    file:make_dir("/tmp/htdocs"),
    {ok, Pid} = inets:start(httpd, [
        {port, 0},
        {server_name, "httpd_test"},
        {server_root, "/tmp"},
        {document_root, "/tmp/htdocs"},
        {bind_address, {1, 1, 1, Idx}}
    ]),
    Pid.

%webservers() ->
%    lists:map(fun make_webserver/1, lists:seq(1,3)).

webserver(Pid) ->
    Info = httpd:info(Pid),
    Port = proplists:get_value(port, Info),
    IP = proplists:get_value(bind_address, Info),
    {IP, Port}.

add_webserver(VIP, {IP, Port}) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {add, {IP, {IP, Port}}}}]}).

remove_webserver(VIP, {IP, Port}) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {remove, {IP, {IP, Port}}}}]}).

remove_vip(VIP) ->
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{remove, {VIP, riak_dt_orswot}}]}).


test_vip(VIP) ->
    %% Wait for lashup state to take effect
    timer:sleep(1000),
    test_vip(3, VIP).

test_vip(0, _) ->
    error;
test_vip(Tries, VIP = {tcp, IP0, Port}) ->
    IP1 = inet:ntoa(IP0),
    URI = lists:flatten(io_lib:format("http://~s:~b/", [IP1, Port])),
    case httpc:request(get, {URI, _Headers = []}, [{timeout, 500}, {connect_timeout, 500}], []) of
        {ok, _} ->
            ok;
        {error, _} ->
            test_vip(Tries - 1, VIP)
    end.

test_basic(_Config) ->
    timer:sleep(1000),
    W1 = make_webserver(1),
    W2 = make_webserver(2),
    VIP1 = {tcp, {11, 0, 0, 1}, 8080},
    add_webserver(VIP1, webserver(W1)),
    ok = test_vip(VIP1),
    remove_webserver(VIP1, webserver(W1)),
    inets:stop(stand_alone, W1),
    add_webserver(VIP1, webserver(W2)),
    ok = test_vip(VIP1),
    remove_webserver(VIP1, webserver(W2)),
    error = test_vip(VIP1),
    remove_vip(VIP1),
    error = test_vip(VIP1).
