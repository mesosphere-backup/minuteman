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

-include_lib("stdlib/include/ms_transform.hrl").
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
  Metrics = metrics_for_path(wrq:path(RD), wrq:path_info(RD)),
  {jsx:encode(Metrics), RD, Ctx}.

%%--------------------------------------------------------------------
%% @doc
%% This is the top-level view of stats for a node.
%% @end
%%--------------------------------------------------------------------
metrics_for_path("/metrics", _) ->
  all_metrics();
metrics_for_path("/vips", _) ->
  vip_metrics();
metrics_for_path("/vips/", _) ->
  vip_metrics();
metrics_for_path(_, [{vip, Vip}]) ->
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
metrics_for_path(_, [{backend, Backend}]) ->
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

all_metrics() ->
  Selector = ets:fun2ms(fun(_Metric = {Name, Type, Enabled}) when Enabled == enabled -> {Name, Type} end),
  Metrics = exometer:select(Selector),
  lists:foldl(fun metric_to_json/2, #{}, Metrics).

metric_to_json({MetricName, MetricType}, Acc) ->
  lager:debug("Handling Metric: ~p", [MetricName]),
  case exometer:get_value(MetricName) of
    {ok, Value} ->
      Name = metric_name(MetricName, MetricType),
      Dict = maps:from_list(Value),
      Dict1 = Dict#{type => MetricType},
      Acc#{Name => Dict1};
    _ ->
      Acc
  end.

metric_name(MetricName, MetricType) ->
  MetricNameStrings = [to_string(Component) || Component <- MetricName],
  MetricNameStrings2 = MetricNameStrings ++ [to_string(MetricType)],
  FlatList = lists:flatten(string:join(MetricNameStrings2, "_")),
  list_to_binary(FlatList).

to_string({VIP, Port})
    when is_tuple(VIP) andalso is_integer(Port) andalso tuple_size(VIP) == 4 ->
  VIPComponents = [inet:ntoa(VIP), to_string(Port)],
  string:join(VIPComponents, ":");
to_string(Component) when is_binary(Component) ->
  binary_to_list(Component);
to_string(Component) when is_atom(Component) ->
  atom_to_list(Component);
to_string(Component) when is_list(Component) ->
  Component;
to_string(Name) ->
  SimpleFormat = io_lib:format("~p", [Name]),
  SimpleFormat.

vip_metrics() ->
  % get all vips
  % get ewma for all current backends
  % get stats for each
  LiveVips = minuteman_vip_server:get_vips(),
  LiveVipMetrics = orddict:fold(fun (Vip, Backends, AccIn) ->
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
