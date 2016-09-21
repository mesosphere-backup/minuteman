-module(minuteman_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-define(DEFAULT_CONFIG_DIR, "/opt/mesosphere/etc/minuteman.config.d").
%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    load_config_files(),
    {ok, _} = application:ensure_all_started(exometer_core),
    minuteman_metrics:setup(),
    minuteman_sup:start_link().

stop(_State) ->
    ok.

load_config_files() ->
    case file:list_dir(?DEFAULT_CONFIG_DIR) of
      {ok, []} ->
        lager:info("Found an empty config directory: ~p", [?DEFAULT_CONFIG_DIR]);
      {error, enoent} ->
        lager:info("Couldn't find config directory: ~p", [?DEFAULT_CONFIG_DIR]);
      {ok, Filenames} ->
        AbsFilenames = lists:map(fun abs_filename/1, Filenames),
        lists:foreach(fun load_config_file/1, AbsFilenames)
    end.

abs_filename(Filename) ->
    filename:absname(Filename, ?DEFAULT_CONFIG_DIR).

load_config_file(Filename) ->
    case file:consult(Filename) of
        {ok, []} ->
            lager:info("Found an empty config file: ~p~n", [Filename]);
        {error, eacces} ->
            lager:info("Couldn't load config: ~p", [Filename]);
        {ok, Result} ->
            load_config(Result),
            lager:info("Loaded config: ~p", [Filename])
    end.

load_config([Result = [_]]) ->
    lists:foreach(fun load_app_config/1, Result).

load_app_config({App, Options}) ->
    lists:foreach(fun({OptionKey, OptionValue}) -> application:set_env(App, OptionKey, OptionValue) end, Options).

