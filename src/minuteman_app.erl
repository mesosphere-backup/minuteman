-module(minuteman_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    {ok, _} = application:ensure_all_started(exometer_core),
    minuteman_metrics:setup(),
    minuteman_sup:start_link().

stop(_State) ->
    ok.
