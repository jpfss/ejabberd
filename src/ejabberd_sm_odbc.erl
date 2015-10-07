%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2015, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  9 Mar 2015 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_sm_odbc).

-behaviour(ejabberd_sm).

%% API
-export([init/0,
	 set_session/1,
	 delete_session/1,
	 get_sessions/0,
	 get_sessions/1,
	 get_sessions/2,
	 get_session/3,
	 get_node_sessions/1,
	 delete_node/1,
	 get_sessions_number/0]).

-include("ejabberd.hrl").
-include("ejabberd_sm.hrl").
-include("logger.hrl").
-include("jlib.hrl").

%%%===================================================================
%%% API
%%%===================================================================
-spec init() -> ok | {error, any()}.
init() ->
    Node = ejabberd_odbc:escape(jlib:atom_to_binary(node())),
    ?INFO_MSG("Cleaning SQL SM table...", []),
    lists:foldl(
      fun(Host, ok) ->
	      case ejabberd_odbc:sql_query(
		     Host, [<<"delete from sm where node='">>, Node, <<"'">>]) of
		  {updated, _} ->
		      ok;
		  Err ->
		      ?ERROR_MSG("failed to clean 'sm' table: ~p", [Err]),
		      Err
	      end;
	 (_, Err) ->
	      Err
      end, ok, ?MYHOSTS).

set_session(#session{sid = {Now, Pid}, usr = {U, LServer, R},
		     priority = Priority, info = Info}) ->
    Username = ejabberd_odbc:escape(U),
    Resource = ejabberd_odbc:escape(R),
    InfoS = ejabberd_odbc:encode_term(Info),
    PrioS = enc_priority(Priority),
    TS = now_to_timestamp(Now),
    PidS = list_to_binary(erlang:pid_to_list(Pid)),
    Node = ejabberd_odbc:escape(jlib:atom_to_binary(node(Pid))),
    case odbc_queries:update(
	   LServer,
	   <<"sm">>,
	   [<<"usec">>, <<"pid">>, <<"node">>, <<"username">>,
	    <<"resource">>, <<"priority">>, <<"info">>],
	   [TS, PidS, Node, Username, Resource, PrioS, InfoS],
	   [<<"username='">>, Username, <<"' and resource='">>, Resource, <<"'">>]) of
	ok ->
	    ok;
	Err ->
	    ?ERROR_MSG("failed to update 'sm' table: ~p", [Err])
    end.

delete_session({LUser, LServer, LResource}) ->
    Username = ejabberd_odbc:escape(LUser),
    Resource = ejabberd_odbc:escape(LResource),
    ejabberd_odbc:sql_query(
      LServer, [<<"delete from sm where username='">>,
                Username, <<"' and resource='">>, Resource, <<"'">>]),
    ok.

get_sessions() ->
    lists:flatmap(
      fun(LServer) ->
	      get_sessions(LServer)
      end, ?MYHOSTS).

get_sessions(LServer) ->
    case ejabberd_odbc:sql_query(
	   LServer, [<<"select usec, pid, username, ">>,
		     <<"resource, priority, info from sm">>]) of
	{selected, _, Rows} ->
	    [row_to_session(LServer, Row) || Row <- Rows];
	Err ->
	    ?ERROR_MSG("failed to select from 'sm' table: ~p", [Err]),
	    []
    end.

get_sessions(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    case ejabberd_odbc:sql_query(
	   LServer, [<<"select usec, pid, username, ">>,
		     <<"resource, priority, info from sm where ">>,
		     <<"username='">>, Username, <<"'">>]) of
	{selected, _, Rows} ->
	    [row_to_session(LServer, Row) || Row <- Rows];
	Err ->
	    ?ERROR_MSG("failed to select from 'sm' table: ~p", [Err]),
	    []
    end.

get_session(LUser, LServer, LResource) ->
    Username = ejabberd_odbc:escape(LUser),
    Resource = ejabberd_odbc:escape(LResource),
    case ejabberd_odbc:sql_query(
	   LServer, [<<"select usec, pid, username, ">>,
		     <<"resource, priority, info from sm where ">>,
		     <<"username='">>, Username, <<"' and resource='">>,
		     Resource, <<"'">>]) of
	{selected, _, []} ->
	    {error, notfound};
	{selected, _, [Row]} ->
	    {ok, row_to_session(LServer, Row)};
	Err ->
	    ?ERROR_MSG("failed to select from 'sm' table: ~p", [Err]),
	    {error, notfound}
    end.

get_node_sessions(Node) ->
    SNode = ejabberd_odbc:escape(jlib:atom_to_binary(Node)),
    lists:flatmap(
      fun(Host) ->
              case ejabberd_odbc:sql_query(
                     Host, [<<"select usec, pid, username, ">>,
                            <<"resource, priority, info from sm ">>,
                            <<"where node='">>, SNode, <<"'">>]) of
                  {selected, _, Rows} ->
                      [row_to_session(Host, Row) || Row <- Rows];
		  Err ->
                      ?ERROR_MSG("failed to select from 'sm' table: ~p", [Err]),
		      []
	      end
      end, ?MYHOSTS).

delete_node(Node) ->
    SNode = ejabberd_odbc:escape(jlib:atom_to_binary(Node)),
    lists:foreach(
      fun(Host) ->
	      ejabberd_odbc:sql_query(
                Host, [<<"delete from sm where node='">>, SNode, <<"'">>])
      end, ?MYHOSTS).

get_sessions_number() ->
    lists:foldl(
      fun(Host, Acc) ->
              case ejabberd_odbc:sql_query(
                     Host, [<<"select count(*) from sm">>]) of
                  {selected, _, [[Count]]} ->
                      jlib:binary_to_integer(Count);
		  Err ->
                      ?ERROR_MSG("failed to select from 'sm' table: ~p", [Err]),
		      0
	      end + Acc
      end, 0, ?MYHOSTS).

%%%===================================================================
%%% Internal functions
%%%===================================================================
now_to_timestamp({MSec, Sec, USec}) ->
    jlib:integer_to_binary((MSec * 1000000 + Sec) * 1000000 + USec).

timestamp_to_now(TS) ->
    I = jlib:binary_to_integer(TS),
    Head = I div 1000000,
    USec = I rem 1000000,
    MSec = Head div 1000000,
    Sec = Head div 1000000,
    {MSec, Sec, USec}.

dec_priority(Prio) ->
    case catch jlib:binary_to_integer(Prio) of
	{'EXIT', _} ->
	    undefined;
	Int ->
	    Int
    end.

enc_priority(undefined) ->
    <<"">>;
enc_priority(Int) when is_integer(Int) ->
    jlib:integer_to_binary(Int).

row_to_session(LServer, [USec, PidS, User, Resource, PrioS, InfoS]) ->
    Now = timestamp_to_now(USec),
    Pid = erlang:list_to_pid(binary_to_list(PidS)),
    Priority = dec_priority(PrioS),
    Info = ejabberd_odbc:decode_term(InfoS),
    #session{sid = {Now, Pid}, us = {User, LServer},
	     usr = {User, LServer, Resource},
	     priority = Priority,
	     info = Info}.
