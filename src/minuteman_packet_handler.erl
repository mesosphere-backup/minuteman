%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:36 AM
%%%-------------------------------------------------------------------
-module(minuteman_packet_handler).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, handle/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-include_lib("pkt/include/pkt.hrl").

-include_lib("kernel/include/inet.hrl").

-include("enfhackery.hrl").
-define(SERVER, ?MODULE).

-record(state, {socket}).

%%%===================================================================
%%% API
%%%===================================================================

handle(Payload) ->
  catch gen_server:call(?SERVER, {handle_payload, Payload}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call({handle_payload, Payload}, _From, State) ->
  do_handle(Payload),
  {reply, ok, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
  State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
  Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

is_local(IP) ->
  {ok, Addresses} = inet:getifaddrs(),
  is_local(IP, Addresses).
is_local(IP, []) ->
  false;
is_local(IP, [{_Ifname, Ifopt}|Interfaces]) ->
  Addrs = [Addr ||{addr, Addr} <- Ifopt],
  case lists:member(IP, Addrs) of
    true ->
      true;
    false ->
      is_local(IP, Interfaces)
  end.

do_handle(Payload) ->
  [IP, TCP|_] = pkt:decapsulate(ipv4, Payload),
  DstAddr = IP#ipv4.daddr,
  DstPort = TCP#tcp.dport,
  case minuteman_vip_server:get_backend(DstAddr, DstPort) of
    {ok, Backend = {BackendIP, BackendPort}} ->
      lager:debug("Backend: ~p", [Backend]),
      SrcAddr = IP#ipv4.saddr,
      SrcPort = TCP#tcp.sport,
      NewSrcAddr = case {is_local(SrcAddr), is_local(BackendIP)} of
                   {true, true} ->
                     {127,0,0,1};
                   _ ->
                     SrcAddr
      end,
      Mapping = #mapping{orig_src_ip = SrcAddr,
        orig_src_port = SrcPort,
        orig_dst_ip = DstAddr,
        orig_dst_port = DstPort,
        new_src_ip = NewSrcAddr,
        new_src_port = SrcPort - 31743,
        new_dst_ip = BackendIP,
        new_dst_port = BackendPort},

      lager:debug("Mapping: ~p", [Mapping]),
      minuteman_ct:handle_mapping(Mapping);

    _ ->
      lager:debug("Could not map connection")
  end.

