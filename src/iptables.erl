%%%-------------------------------------------------------------------
%%% @author Eugene Kalinin <e.v.kalinin@gmail.com>
%%% @copyright (C) 2014 Eugene Kalinin
%%% @doc Wrapper for iptables.
%%% @end
%%%
%%%-------------------------------------------------------------------
%%% Vendored from: https://github.com/ekalinin/erlang-iptables
-module(iptables).
-author('e.v.kalinin@gmail.com').

-export([append/2, append/3, check/2,  check/3]).
-export([delete/2, delete/3, insert/2, insert/3, insert/4]).
-export([list/0,   list/1,   list/2]).
-export([flush/0,  flush/1,  flush/2]).
-export([zero/0,   zero/1,   zero/2]).
-export([create_chain/1,     create_chain/2]).
-export([delete_chain/0,     delete_chain/1,     delete_chain/2]).
-export([rename_chain/2,     rename_chain/3]).
-export([policy/2, policy/3, is_installed/0]).

%% Default command: sudo iptables
-ifndef(BIN).
-define(BIN, "iptables").
-endif.

%% Default table: filter
-ifndef(DEFAULT_TABLE).
-define(DEFAULT_TABLE, filter).
-endif.

-define(CMD(S), os:cmd(S)).

-include("iptables.hrl").


%% @doc Append rule to the end of the selected chain of the default table.
-spec append(Chain :: chain(), Rule :: string()) -> {ok, string()}.
append(Chain, Rule) ->
    append(?DEFAULT_TABLE, Chain, Rule).

%% @doc Append rule to the end of the selected chain of the selected table.
-spec append(Table :: table(), Chain :: chain(), Rule :: string()) 
        -> {ok, string()}.
append(Table, Chain, Rule) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --append " ++ C ++ " " ++ Rule)}.


%% @doc Check whether a rule matching the specification
%%      does exist in the selected chain of the default table.
-spec check(Chain :: chain(), Rule :: string()) -> {ok, string()}.
check(Chain, Rule) ->
    check(?DEFAULT_TABLE, Chain, Rule).

%% @doc Check whether a rule matching the specification
%%      does exist in the selected chain of the selected table.
-spec check(Table :: table(), Chain :: chain(), Rule :: string())
        -> {ok, string()}.
check(Table, Chain, Rule) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --check " ++ C ++ " " ++ Rule)}.


%% @doc Delete rule from the selected chain of the default table.
-spec delete(Chain :: chain(), Rule :: string()) -> {ok, string()}.
delete(Chain, Rule) ->
    delete(?DEFAULT_TABLE, Chain, Rule).

-spec delete(Table :: table(), Chain :: chain(), Rule :: string())
        -> {ok, string()}.
delete(Table, Chain, Rule) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --delete " ++ C ++ " " ++ Rule)}.


%% @doc Insert rule in the selected chain as the given rule number.
-spec insert(Chain :: chain(), Rule :: string()) -> {ok, string()}.
insert(Chain, Rule) ->
    insert(?DEFAULT_TABLE, Chain, Rule, 1).

-spec insert(Table :: table(), Chain :: chain(), Rule :: string())
        -> {ok, string()}.
insert(Table, Chain, Rule) ->
    insert(Table, Chain, Rule, 1).

-spec insert(Table :: table(), Chain :: chain(),
             Rule :: string(), Pos :: integer()) -> {ok, string()}.
insert(Table, Chain, Rule, Pos) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --insert " ++ C ++ " " ++
                                  integer_to_list(Pos) ++ " " ++ Rule)}.
 
%% @doc Print all rules in the selected chain.
%%      If no chain is selected, all chains are printed like iptables-save.
-spec list() -> {ok, string()}.
list() ->
    list(none).

-spec list(Chain :: chain()) -> {ok, string()}.
list(Chain) ->
    list(?DEFAULT_TABLE, Chain).

-spec list(Table :: table(), Chain :: chain()) -> {ok, string()}.
list(Table, none) ->
    T = atom_to_list(Table),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --list-rules")};
list(Table, Chain) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --list-rules " ++ C)}.


%% @doc Flush the selected chain (all the chains in the table if none is given).
-spec flush() -> {ok, string()}.
flush() ->
    flush(none).

-spec flush(Chain :: chain()) -> {ok, string()}.
flush(Chain) ->
    flush(?DEFAULT_TABLE, Chain).

-spec flush(Table :: table(), Chain :: chain()) -> {ok, string()}.
flush(Table, none) ->
    T = atom_to_list(Table),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --flush")};
flush(Table, Chain) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --flush " ++ C)}.


%% @doc Zero the packet and byte counters in all chains,
%%      or only the given chain, or only the given rule in a chain.
-spec zero() -> {ok, string()}.
zero() ->
    zero(none).

-spec zero(Chain :: chain()) -> {ok, string()}.
zero(Chain) ->
    zero(?DEFAULT_TABLE, Chain).

-spec zero(Table :: table(), Chain :: chain()) -> {ok, string()}.
zero(Table, none) ->
    T = atom_to_list(Table),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --zero")};
zero(Table, Chain) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --zero " ++ C)}.


%% @doc Create a new user-defined chain by the given name.
-spec create_chain(Chain :: chain()) -> {ok, string()}.
create_chain(Chain) ->
    create_chain(?DEFAULT_TABLE, Chain).

-spec create_chain(Table :: table(), Chain :: chain()) -> {ok, string()}.
create_chain(Table, Chain) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --new-chain " ++ C)}.


%% @doc Delete the optional user-defined chain specified.
-spec delete_chain() -> {ok, string()}.
delete_chain() ->
    delete_chain(none).

-spec delete_chain(Chain :: chain()) -> {ok, string()}.
delete_chain(Chain) ->
    delete_chain(?DEFAULT_TABLE, Chain).

-spec delete_chain(Table :: table(), Chain :: chain()) -> {ok, string()}.
delete_chain(Table, none) ->
    T = atom_to_list(Table),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --delete-chain")};
delete_chain(Table, Chain) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --delete-chain " ++ C)}.


%% @doc Rename the user specified chain to the user supplied name.
-spec rename_chain(OldChain :: chain(), NewChain :: chain())
        -> {ok, string()}.
rename_chain(OldChain, NewChain) ->
    rename_chain(?DEFAULT_TABLE, OldChain, NewChain).

-spec rename_chain(Table :: table(), OldChain :: chain(),
                  NewChain :: chain()) -> {ok, string()}.
rename_chain(Table, OldChain, NewChain) ->
    T = atom_to_list(Table),
    C1 = string:to_upper(atom_to_list(OldChain)),
    C2 = string:to_upper(atom_to_list(NewChain)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --rename-chain " ++ C1 ++ " " ++ C2)}.


%% @doc Set the policy for the chain to the given target.
-spec policy(Chain :: chain(), Target :: target()) -> {ok, string()}.
policy(Chain, Target) ->
    policy(?DEFAULT_TABLE, Chain, Target).

-spec policy(Table :: table(), Chain :: chain(), Target :: target())
        -> {ok, string()}.
policy(Table, Chain, Target) ->
    T = atom_to_list(Table),
    C = string:to_upper(atom_to_list(Chain)),
    TGT = string:to_upper(atom_to_list(Target)),
    {ok, ?CMD(?BIN ++ " -t " ++ T ++ " --policy " ++ C ++ " " ++ TGT)}.


%% @doc Check is "iptables" installed.

-spec is_installed() -> {ok, boolean()}.
is_installed() ->
    {ok, os:cmd('which iptables | wc -l') == "1\n"}.
