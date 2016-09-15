-module(minuteman_restart_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() -> all(os:cmd("id -u")).

% tests that need root
all("0\n") -> [test_restart].

% tests that do not need root
all(_) -> [].

test_restart(_Config) ->
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman),
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman),
  {ok, _} = application:ensure_all_started(minuteman),
  ok = application:stop(minuteman).

