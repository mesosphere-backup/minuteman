%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2016, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 19. Jan 2016 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_metrics).
-author("Tyler Neely").
-author("Sargun Dhillon").


-export([update/3, setup/0, inspect_backend/1]).

-ifdef(TEST).
update(_Metric, _Value, _Type) ->
  ok.
-else.
update(Metric, Value, Type) ->
  case exometer:update(Metric, Value) of
    {error, not_found} ->
      ok = exometer:ensure(Metric, Type, [{cache, 15}]),
      ok = exometer:update(Metric, Value);
    _ -> ok
  end.
-endif.

inspect_backend(Backend) ->
  #{
    successes_one => get_value([backend, Backend, successes], one),
    failures_one => get_value([backend, Backend, failures], one),
    p99 => get_value([backend, Backend, connect_latency], p99)
  }.

get_value(Metric, Key) ->
  value_or_undefined(exometer:get_value(Metric, Key)).
value_or_undefined({ok, [{_Key, Value}]}) ->
  Value;
value_or_undefined({ok, Value}) ->
    Value;
value_or_undefined({error, not_found}) ->
    undefined.

setup() ->
  exometer:ensure([erlang, system_info],
    {
      function, erlang, system_info, ['$dp'], value,
      [port_count, process_count, thread_pool_size, kernel_poll, logical_processors]
    }, []),
  exometer:ensure([erlang, memory],
    {
      function, erlang, memory, ['$dp'], value,
      [atom, atom_used, processes, processes_used, ets, total, maximum, system]
    }, []),
  exometer:ensure([erlang, statistics],
    {
      function, erlang, statistics, ['$dp'], value,
      ['run_queue']
    }, []).
