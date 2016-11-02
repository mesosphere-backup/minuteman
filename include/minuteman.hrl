%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:43 AM
%%%-------------------------------------------------------------------
-author("sdhillon").
-author("Tyler Neely").

-define(SERVER_NAME_WITH_NUM(Num),
  list_to_atom(lists:flatten([?MODULE_STRING, "_", integer_to_list(Num)]))).

-type ip_port() :: {inet:ip4_address(), inet:port_number()}.


%-define(LOG(Formatting, Args), lager:debug(Formatting, Args)).
-define(MM_LOG(Formatting, Args), ok).

%-define(LOG(Formatting), lager:debug(Formatting)).
-define(MM_LOG(Formatting), ok).


-define(VIPS_KEY, [minuteman, vips]).
