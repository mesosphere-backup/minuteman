%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. Jan 2016 11:23 PM
%%%-------------------------------------------------------------------
-module(minuteman_wm_home).
-author("sdhillon").

-export([init/1,
  allowed_methods/2,
  content_types_provided/2,
  reply/2,
  html_reply/2]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("minuteman.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-record(context, {}).

init(_) ->
  {ok, #context{}}.

allowed_methods(RD, Ctx) ->
  {['GET'], RD, Ctx}.


content_types_provided(RD, Ctx) ->
  {[
    {"text/plain", reply},
    {"text/html", html_reply}
  ], RD, Ctx}.


reply(RD, Ctx) ->
  Reply = "You have reached this page in error\n",
  {Reply, RD, Ctx}.

html_reply(RD, Ctx) ->
  DispPath = wrq:disp_path(RD),
  case DispPath of
    "" ->
      {ok, Reply} = read_priv_file("index.html"),
      {Reply, RD, Ctx};
    _ ->
      {ok, Reply} = read_priv_file(DispPath),
      {Reply, RD, Ctx}
  end.

read_priv_file(Filename) ->
  case code:priv_dir(minuteman) of
    {error, bad_name} ->
      % This occurs when not running as a release; e.g., erl -pa ebin
      % Of course, this will not work for all cases, but should account
      % for most
      PrivDir = "priv";
    PrivDir ->
      % In this case, we are running in a release and the VM knows
      % where the application (and thus the priv directory) resides
      % on the file system
      ok
  end,
  file:read_file(filename:join([PrivDir, "assets", Filename])).