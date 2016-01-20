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

-export([update/3]).

update(Metric, Value, Type) ->
  case exometer:update(Metric, Value) of
    {error, not_found} ->
      ok = exometer:new(Metric, Type),
      ok = exometer:update(Metric, Value);
    _ -> ok
  end.
