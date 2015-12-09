%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:43 AM
%%%-------------------------------------------------------------------
-author("sdhillon").

-record(mapping, {
  orig_src_ip,
  orig_src_port,
  orig_dst_ip,
  orig_dst_port,
  new_src_ip,
  new_src_port,
  new_dst_ip,
  new_dst_port
  }).