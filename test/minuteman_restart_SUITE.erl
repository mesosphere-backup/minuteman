-module(minuteman_restart_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
  [test_init,
   test_init].

test_init(_Config) -> ok.

init_per_testcase(_, Config) ->
  {ok, _} = application:ensure_all_started(minuteman),
  Config.

end_per_testcase(_, _Config) -> 
  ok = application:stop(minuteman).
