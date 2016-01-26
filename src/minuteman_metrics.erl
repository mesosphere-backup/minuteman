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


-export([update/3, setup/0, lashup/1]).

-ifdef(TEST).
update(_Metric, _Value, _Type) ->
  ok.
-else.
update(Metric, Value, Type) ->
  case exometer:update(Metric, Value) of
    {error, not_found} ->
      ok = exometer:ensure(Metric, Type, []),
      ok = exometer:update(Metric, Value);
    _ -> ok
  end.
-endif.


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
    }, []),
  exometer:ensure([lashup],
    {
      function, ?MODULE, lashup, ['$dp'], value,
      ['active_view', 'passive_view']
    }, [{cache, 5000}]).

lashup(active_view) ->
  lashup_hyparview_membership:get_active_view();

lashup(passive_view) ->
  lashup_hyparview_membership:get_active_view().
