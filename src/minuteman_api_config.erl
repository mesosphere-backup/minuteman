%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2016, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 12. Jan 2016 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_api_config).
-author("Tyler Neely").

-export([
    dispatch/0,
    web_config/0
]).

-spec dispatch() -> [webmachine_dispatcher:route()].
dispatch() ->
    lists:flatten([
        {['*'], minuteman_api, []}
    ]).

web_config() ->
    {ok, App} = application:get_application(?MODULE),
    [
        {ip, minuteman_config:api_listen_ip()},
        {port, minuteman_config:api_listen_port()},
        {log_dir, "priv/log"},
        {dispatch, dispatch()}
    ].
