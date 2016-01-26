%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Jan 2016 11:38 PM
%%%-------------------------------------------------------------------
-module(minuteman_wm_lashup).
-author("sdhillon").


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
  RD1 = wrq:set_resp_header("Path", wrq:path(RD), RD),
  RD2 = wrq:set_resp_header("Disp-Path", wrq:disp_path(RD), RD1),
  Reply = handle_lashup(wrq:path(RD2), RD2),
  case Reply of
    {halt, _} ->
      {Reply, RD2, Ctx};
    _ ->
      {jsx:encode(Reply), RD2, Ctx}
  end.

%% TODO: Turn this into POST
handle_lashup("/lashup/add_node", RD) ->
  case wrq:get_qs_value("node", RD) of
    undefined ->
      {halt, 503};
    Node ->
      NodeAtom = list_to_atom(Node),
      gen_server:call(lashup_hyparview_membership, {do_connect, NodeAtom})
  end;
handle_lashup("/lashup/gm", _) ->
  gm();
handle_lashup("/lashup/active_view", _) ->
  lashup_hyparview_membership:get_active_view();
handle_lashup("/lashup/passive_view", _) ->
  lashup_hyparview_membership:get_passive_view();
handle_lashup(_, _) ->
  {halt, 404}.


-compile(export_all).

gm() ->
  GM = lashup_gm:gm(),
  [check_neighbor(Neighbor) || Neighbor <- GM].

check_neighbor(Neighbor) ->
  maps:map(fun check_neighbor_entries/2, Neighbor).

check_neighbor_entries(metadata, Value = #{ips := IPs}) ->
  [PrimaryIP|_] = IPs,
  Reachable = [{PrimaryIP, true}] == ets:lookup(reachability_cache, PrimaryIP),
  Value2 = Value#{reachable => Reachable},
  maps:map(fun check_metadata_entries/2, Value2);
check_neighbor_entries(metadata, Value) ->
  Value2 = Value#{reachable => unknown},
  Value2;
check_neighbor_entries(_Key, Value) ->
  Value.

check_metadata_entries(ips, IPs) ->

  [list_to_binary(inet:ntoa(IP)) || IP <- IPs];
check_metadata_entries(_Key, Value) ->
  Value.