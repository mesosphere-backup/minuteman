%%%-------------------------------------------------------------------
%%% @author Tyler Neely
%%% @copyright (C) 2016, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 12. Jan 2016 11:44 PM
%%%-------------------------------------------------------------------
-module(minuteman_api).
-author("Tyler Neely").

-export([init/1,
         allowed_methods/2,
         content_types_provided/2,
         to_json/2]).

-include("minuteman.hrl").
-include_lib("webmachine/include/webmachine.hrl").

init(_) -> {ok, undefined}.

allowed_methods(RD, Ctx) ->
  {['GET'], RD, Ctx}.

content_types_provided(RD, Ctx) ->
  {[
    {"application/json", to_json}
    %% TODO text/plain and text/html
   ], RD, Ctx}.

to_json(RD, Ctx) ->
  Metrics = metrics_for_path(wrq:path(RD)),
  {jsx:encode(Metrics), RD, Ctx}.

%%--------------------------------------------------------------------
%% @doc
%% This is the top-level view of stats for a node.
%% @end
%%--------------------------------------------------------------------
metrics_for_path("/vips" ++ _Rest) ->
  vip_metrics();
metrics_for_path("/vip/" ++ Vip) ->
  case parse_ip_port(Vip) of
    {IP, Port} ->
      case minuteman_vip_server:get_backends_for_vip(IP, Port) of
        {ok, Backends} ->
          metrics_for_backends(Backends);
        error ->
          #{error => no_backends}
      end;
    _ ->
      #{error => invalid_vip}
  end;
metrics_for_path("/backend/" ++ Backend) ->
  case parse_ip_port(Backend) of
    {IP, Port} ->
      metrics_for_backend({IP, Port});
    _ ->
      #{error => invalid_backend}
  end.

parse_ip_port(IpPort) ->
  case string:tokens(IpPort, ":") of
    [IPString, Port] ->
      case {string:to_integer(Port), inet:parse_ipv4_address(IPString)} of
        {{ParsedPort, []}, {ok, ParsedIP}} ->
              {ParsedIP, ParsedPort};
        _ ->
          error
      end;
    _ ->
      error
  end.


vip_metrics() ->
  % get all vips
  % get ewma for all current backends
  % get stats for each
  LiveVips = minuteman_vip_server:get_vips(),
  LiveVipMetrics = dict:fold(fun (Vip, Backends, AccIn) ->
                                 VIPIPPort = fmt_ip_port(Vip),
                                 Metrics = metrics_for_backends(Backends),
                                 AccIn#{VIPIPPort => Metrics}
                             end, #{}, LiveVips),

  #{vips => LiveVipMetrics}.


metrics_for_backends(Backends) ->
  lists:foldl(fun (Backend, AccIn) ->
                  BackendIPPort = fmt_ip_port(Backend),
                  Metrics = metrics_for_backend(Backend),
                  AccIn#{BackendIPPort => Metrics}
              end, #{}, Backends).

metrics_for_backend({IP, Port}) ->
  Backend = #backend{tracking = Tracking} = minuteman_ewma:get_ewma({IP, Port}),
  Cost = minuteman_ewma:cost(Backend),
  Healthy = minuteman_ewma:is_open(Tracking),
  LatencyMetrics = case exometer:get_value([connect_latency, backend, {IP, Port}]) of
                     {ok, LM} ->
                       maps:from_list(LM);
                     _ ->
                       #{}
                   end,

  #{
    ewma_cost => Cost,
    total_failures => Tracking#backend_tracking.total_failures,
    total_sucesses => Tracking#backend_tracking.total_successes,
    is_healthy => Healthy,
    latency_last_60s => LatencyMetrics
   }.

fmt_ip_port({_Proto, IP, Port}) ->
  fmt_ip_port({IP, Port});
fmt_ip_port({IP, Port}) ->
  IPString = inet_parse:ntoa(IP),
  List = io_lib:format("~s:~p", [IPString, Port]),
  list_to_binary(List).
