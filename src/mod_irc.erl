%%%----------------------------------------------------------------------
%%% File    : mod_irc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : IRC transport
%%% Created : 15 Feb 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_irc).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-behaviour(gen_server).

-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1, export/1, import_info/0,
	 import/5, closed_connection/3, get_connection_params/3,
         import_start/2, data_to_binary/2]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("adhoc.hrl").

-include("mod_irc.hrl").

-define(DEFAULT_IRC_ENCODING, <<"iso8859-15">>).

-define(DEFAULT_IRC_PORT, 6667).

-define(POSSIBLE_ENCODINGS,
	[<<"koi8-r">>, <<"iso8859-1">>, <<"iso8859-2">>,
	 <<"utf-8">>, <<"utf-8+latin-1">>]).

-record(state, {host = <<"">>        :: binary(),
                server_host = <<"">> :: binary(),
                access = all         :: atom()}).

-define(PROCNAME, ejabberd_mod_irc).

-callback init(binary(), gen_mod:opts()) -> any().
-callback import(binary(), binary(), [binary()]) -> ok.
-callback get_data(binary(), binary(), {binary(), binary()}) ->
    error | empty | irc_data().
-callback set_data(binary(), binary(), {binary(), binary()}, irc_data()) ->
    {atomic, any()}.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE,
			  [Host, Opts], []).

start(Host, Opts) ->
    start_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 temporary, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    stop_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    ejabberd:start_app(iconv),
    MyHost = gen_mod:get_opt_host(Host, Opts,
				  <<"irc.@HOST@">>),
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, Opts),
    Access = gen_mod:get_opt(access, Opts,
                             fun(A) when is_atom(A) -> A end,
                             all),
    catch ets:new(irc_connection,
		  [named_table, public,
		   {keypos, #irc_connection.jid_server_host}]),
    ejabberd_router:register_route(MyHost, Host),
    {ok,
     #state{host = MyHost, server_host = Host,
	    access = Access}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet},
	    #state{host = Host, server_host = ServerHost,
		   access = Access} =
		State) ->
    case catch do_route(Host, ServerHost, Access, From, To,
			Packet)
	of
      {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
      _ -> ok
    end,
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ejabberd_router:unregister_route(State#state.host), ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host,
				   ejabberd_mod_irc_sup),
    ChildSpec = {Proc,
		 {ejabberd_tmp_sup, start_link,
		  [Proc, mod_irc_connection]},
		 permanent, infinity, supervisor, [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host,
				   ejabberd_mod_irc_sup),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

do_route(Host, ServerHost, Access, From, To, Packet) ->
    case acl:match_rule(ServerHost, Access, From) of
      allow -> do_route1(Host, ServerHost, From, To, Packet);
      _ ->
	  #xmlel{attrs = Attrs} = Packet,
	  Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
	  ErrText = <<"Access denied by service policy">>,
	  Err = jlib:make_error_reply(Packet,
				      ?ERRT_FORBIDDEN(Lang, ErrText)),
	  ejabberd_router:route(To, From, Err)
    end.

do_route1(Host, ServerHost, From, To, Packet) ->
    #jid{user = ChanServ, resource = Resource} = To,
    #xmlel{} = Packet,
    case ChanServ of
      <<"">> ->
	  case Resource of
	    <<"">> ->
		case jlib:iq_query_info(Packet) of
		  #iq{type = get, xmlns = (?NS_DISCO_INFO) = XMLNS,
		      sub_el = SubEl, lang = Lang} =
		      IQ ->
		      Node = fxml:get_tag_attr_s(<<"node">>, SubEl),
		      Info = ejabberd_hooks:run_fold(disco_info, ServerHost,
						     [],
						     [ServerHost, ?MODULE,
						      <<"">>, <<"">>]),
		      case iq_disco(ServerHost, Node, Lang) of
			[] ->
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"query">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children = []}]},
			    ejabberd_router:route(To, From,
						  jlib:iq_to_xml(Res));
			DiscoInfo ->
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"query">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children =
							DiscoInfo ++ Info}]},
			    ejabberd_router:route(To, From, jlib:iq_to_xml(Res))
		      end;
		  #iq{type = get, xmlns = (?NS_DISCO_ITEMS) = XMLNS,
		      sub_el = SubEl, lang = Lang} =
		      IQ ->
		      Node = fxml:get_tag_attr_s(<<"node">>, SubEl),
		      case Node of
			<<>> ->
			    ResIQ = IQ#iq{type = result,
					  sub_el =
					      [#xmlel{name = <<"query">>,
						      attrs =
							  [{<<"xmlns">>,
							    XMLNS}],
						      children = []}]},
			    Res = jlib:iq_to_xml(ResIQ);
			<<"join">> ->
			    ResIQ = IQ#iq{type = result,
					  sub_el =
					      [#xmlel{name = <<"query">>,
						      attrs =
							  [{<<"xmlns">>,
							    XMLNS}],
						      children = []}]},
			    Res = jlib:iq_to_xml(ResIQ);
			<<"register">> ->
			    ResIQ = IQ#iq{type = result,
					  sub_el =
					      [#xmlel{name = <<"query">>,
						      attrs =
							  [{<<"xmlns">>,
							    XMLNS}],
						      children = []}]},
			    Res = jlib:iq_to_xml(ResIQ);
			?NS_COMMANDS ->
			    ResIQ = IQ#iq{type = result,
					  sub_el =
					      [#xmlel{name = <<"query">>,
						      attrs =
							  [{<<"xmlns">>, XMLNS},
							   {<<"node">>, Node}],
						      children =
							  command_items(ServerHost,
									Host,
									Lang)}]},
			    Res = jlib:iq_to_xml(ResIQ);
			_ ->
			    Txt = <<"Node not found">>,
			    Res = jlib:make_error_reply(
				    Packet, ?ERRT_ITEM_NOT_FOUND(Lang, Txt))
		      end,
		      ejabberd_router:route(To, From, Res);
		  #iq{xmlns = ?NS_REGISTER} = IQ ->
		      process_register(ServerHost, Host, From, To, IQ);
		  #iq{type = get, xmlns = (?NS_VCARD) = XMLNS,
		      lang = Lang} =
		      IQ ->
		      Res = IQ#iq{type = result,
				  sub_el =
				      [#xmlel{name = <<"vCard">>,
					      attrs = [{<<"xmlns">>, XMLNS}],
					      children = iq_get_vcard(Lang)}]},
		      ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
		  #iq{type = set, xmlns = ?NS_COMMANDS, lang = Lang,
		      sub_el = SubEl} =
		      IQ ->
		      Request = adhoc:parse_request(IQ),
		      case lists:keysearch(Request#adhoc_request.node, 1,
					   commands(ServerHost))
			  of
			{value, {_, _, Function}} ->
			    case catch Function(From, To, Request) of
			      {'EXIT', Reason} ->
				  ?ERROR_MSG("~p~nfor ad-hoc handler of ~p",
					     [Reason, {From, To, IQ}]),
				  Res = IQ#iq{type = error,
					      sub_el =
						  [SubEl,
						   ?ERR_INTERNAL_SERVER_ERROR]};
			      ignore -> Res = ignore;
			      {error, Error} ->
				  Res = IQ#iq{type = error,
					      sub_el = [SubEl, Error]};
			      Command ->
				  Res = IQ#iq{type = result, sub_el = [Command]}
			    end,
			    if Res /= ignore ->
				   ejabberd_router:route(To, From,
							 jlib:iq_to_xml(Res));
			       true -> ok
			    end;
			_ ->
			    Txt = <<"Node not found">>,
			    Err = jlib:make_error_reply(
				    Packet, ?ERRT_ITEM_NOT_FOUND(Lang, Txt)),
			    ejabberd_router:route(To, From, Err)
		      end;
		  #iq{} = _IQ ->
		      Err = jlib:make_error_reply(Packet,
						  ?ERR_FEATURE_NOT_IMPLEMENTED),
		      ejabberd_router:route(To, From, Err);
		  _ -> ok
		end;
	    _ ->
		Err = jlib:make_error_reply(Packet, ?ERR_BAD_REQUEST),
		ejabberd_router:route(To, From, Err)
	  end;
      _ ->
	  case str:tokens(ChanServ, <<"%">>) of
	    [<<_, _/binary>> = Channel, <<_, _/binary>> = Server] ->
		case ets:lookup(irc_connection, {From, Server, Host}) of
		  [] ->
		      ?DEBUG("open new connection~n", []),
		      {Username, Encoding, Port, Password} =
			  get_connection_params(Host, ServerHost, From, Server),
		      ConnectionUsername = case Packet of
					     %% If the user tries to join a
					     %% chatroom, the packet for sure
					     %% contains the desired username.
					     #xmlel{name = <<"presence">>} ->
						 Resource;
					     %% Otherwise, there is no firm
					     %% conclusion from the packet.
					     %% Better to use the configured
					     %% username (which defaults to the
					     %% username part of the JID).
					     _ -> Username
					   end,
		      {ok, Pid} = mod_irc_connection:start(From, Host,
							   ServerHost, Server,
							   ConnectionUsername,
							   Encoding, Port,
							   Password, ?MODULE),
		      ets:insert(irc_connection,
				 #irc_connection{jid_server_host =
						     {From, Server, Host},
						 pid = Pid}),
		      mod_irc_connection:route_chan(Pid, Channel, Resource,
						    Packet),
		      ok;
		  [R] ->
		      Pid = R#irc_connection.pid,
		      ?DEBUG("send to process ~p~n", [Pid]),
		      mod_irc_connection:route_chan(Pid, Channel, Resource,
						    Packet),
		      ok
		end;
	    _ ->
		Lang = fxml:get_tag_attr_s(<<"xml:lang">>, Packet),
		case str:tokens(ChanServ, <<"!">>) of
		  [<<_, _/binary>> = Nick, <<_, _/binary>> = Server] ->
		      case ets:lookup(irc_connection, {From, Server, Host}) of
			[] ->
			    Txt = <<"IRC connection not found">>,
			    Err = jlib:make_error_reply(
				    Packet, ?ERRT_SERVICE_UNAVAILABLE(Lang, Txt)),
			    ejabberd_router:route(To, From, Err);
			[R] ->
			    Pid = R#irc_connection.pid,
			    ?DEBUG("send to process ~p~n", [Pid]),
			    mod_irc_connection:route_nick(Pid, Nick, Packet),
			    ok
		      end;
		  _ ->
		      Txt = <<"Failed to parse chanserv">>,
		      Err = jlib:make_error_reply(
			      Packet, ?ERRT_BAD_REQUEST(Lang, Txt)),
		      ejabberd_router:route(To, From, Err)
		end
	  end
    end.

closed_connection(Host, From, Server) ->
    ets:delete(irc_connection, {From, Server, Host}).

iq_disco(_ServerHost, <<>>, Lang) ->
    [#xmlel{name = <<"identity">>,
	    attrs =
		[{<<"category">>, <<"conference">>},
		 {<<"type">>, <<"irc">>},
		 {<<"name">>,
		  translate:translate(Lang, <<"IRC Transport">>)}],
	    children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_DISCO_INFO}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_MUC}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_REGISTER}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_VCARD}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_COMMANDS}], children = []}];
iq_disco(ServerHost, Node, Lang) ->
    case lists:keysearch(Node, 1, commands(ServerHost)) of
      {value, {_, Name, _}} ->
	  [#xmlel{name = <<"identity">>,
		  attrs =
		      [{<<"category">>, <<"automation">>},
		       {<<"type">>, <<"command-node">>},
		       {<<"name">>, translate:translate(Lang, Name)}],
		  children = []},
	   #xmlel{name = <<"feature">>,
		  attrs = [{<<"var">>, ?NS_COMMANDS}], children = []},
	   #xmlel{name = <<"feature">>,
		  attrs = [{<<"var">>, ?NS_XDATA}], children = []}];
      _ -> []
    end.

iq_get_vcard(Lang) ->
    [#xmlel{name = <<"FN">>, attrs = [],
	    children = [{xmlcdata, <<"ejabberd/mod_irc">>}]},
     #xmlel{name = <<"URL">>, attrs = [],
	    children = [{xmlcdata, ?EJABBERD_URI}]},
     #xmlel{name = <<"DESC">>, attrs = [],
	    children =
		[{xmlcdata,
		  <<(translate:translate(Lang,
					 <<"ejabberd IRC module">>))/binary,
		    "\nCopyright (c) 2003-2016 ProcessOne">>}]}].

command_items(ServerHost, Host, Lang) ->
    lists:map(fun ({Node, Name, _Function}) ->
		      #xmlel{name = <<"item">>,
			     attrs =
				 [{<<"jid">>, Host}, {<<"node">>, Node},
				  {<<"name">>,
				   translate:translate(Lang, Name)}],
			     children = []}
	      end,
	      commands(ServerHost)).

commands(ServerHost) ->
    [{<<"join">>, <<"Join channel">>, fun adhoc_join/3},
     {<<"register">>,
      <<"Configure username, encoding, port and "
	"password">>,
      fun (From, To, Request) ->
	      adhoc_register(ServerHost, From, To, Request)
      end}].

process_register(ServerHost, Host, From, To,
		 #iq{} = IQ) ->
    case catch process_irc_register(ServerHost, Host, From,
				    To, IQ)
	of
      {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]);
      ResIQ ->
	  if ResIQ /= ignore ->
		 ejabberd_router:route(To, From, jlib:iq_to_xml(ResIQ));
	     true -> ok
	  end
    end.

find_xdata_el(#xmlel{children = SubEls}) ->
    find_xdata_el1(SubEls).

find_xdata_el1([]) -> false;
find_xdata_el1([#xmlel{name = Name, attrs = Attrs,
		       children = SubEls}
		| Els]) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
      ?NS_XDATA ->
	  #xmlel{name = Name, attrs = Attrs, children = SubEls};
      _ -> find_xdata_el1(Els)
    end;
find_xdata_el1([_ | Els]) -> find_xdata_el1(Els).

process_irc_register(ServerHost, Host, From, _To,
		     #iq{type = Type, xmlns = XMLNS, lang = Lang,
			 sub_el = SubEl} =
			 IQ) ->
    case Type of
      set ->
	  XDataEl = find_xdata_el(SubEl),
	  case XDataEl of
	    false ->
		Txt1 = <<"No data form found">>,
		IQ#iq{type = error,
		      sub_el = [SubEl, ?ERRT_NOT_ACCEPTABLE(Lang, Txt1)]};
	    #xmlel{attrs = Attrs} ->
		case fxml:get_attr_s(<<"type">>, Attrs) of
		  <<"cancel">> ->
		      IQ#iq{type = result,
			    sub_el =
				[#xmlel{name = <<"query">>,
					attrs = [{<<"xmlns">>, XMLNS}],
					children = []}]};
		  <<"submit">> ->
		      XData = jlib:parse_xdata_submit(XDataEl),
		      case XData of
			invalid ->
			    Txt2 = <<"Incorrect data form">>,
			    IQ#iq{type = error,
				  sub_el = [SubEl, ?ERRT_BAD_REQUEST(Lang, Txt2)]};
			_ ->
			    Node = str:tokens(fxml:get_tag_attr_s(<<"node">>,
								 SubEl),
					      <<"/">>),
			    case set_form(ServerHost, Host, From, Node, Lang,
					  XData)
				of
			      {result, Res} ->
				  IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"query">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children = Res}]};
			      {error, Error} ->
				  IQ#iq{type = error, sub_el = [SubEl, Error]}
			    end
		      end;
		  _ ->
		      Txt3 = <<"Incorrect value of 'type' attribute">>,
		      IQ#iq{type = error,
			    sub_el = [SubEl, ?ERRT_BAD_REQUEST(Lang, Txt3)]}
		end
	  end;
      get ->
	  Node = str:tokens(fxml:get_tag_attr_s(<<"node">>, SubEl),
			    <<"/">>),
	  case get_form(ServerHost, Host, From, Node, Lang) of
	    {result, Res} ->
		IQ#iq{type = result,
		      sub_el =
			  [#xmlel{name = <<"query">>,
				  attrs = [{<<"xmlns">>, XMLNS}],
				  children = Res}]};
	    {error, Error} ->
		IQ#iq{type = error, sub_el = [SubEl, Error]}
	  end
    end.

get_data(ServerHost, Host, From) ->
    LServer = jid:nameprep(ServerHost),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:get_data(LServer, Host, From).

get_form(ServerHost, Host, From, [], Lang) ->
    #jid{user = User, server = Server} = From,
    DefaultEncoding = get_default_encoding(Host),
    Customs = case get_data(ServerHost, Host, From) of
		error ->
		      Txt1 = <<"Database failure">>,
		      {error, ?ERRT_INTERNAL_SERVER_ERROR(Lang, Txt1)};
		empty -> {User, []};
		Data -> get_username_and_connection_params(Data)
	      end,
    case Customs of
      {error, _Error} -> Customs;
      {Username, ConnectionsParams} ->
	  {result,
	   [#xmlel{name = <<"instructions">>, attrs = [],
		   children =
		       [{xmlcdata,
			 translate:translate(Lang,
					     <<"You need an x:data capable client to "
					       "configure mod_irc settings">>)}]},
	    #xmlel{name = <<"x">>,
		   attrs = [{<<"xmlns">>, ?NS_XDATA}],
		   children =
		       [#xmlel{name = <<"title">>, attrs = [],
			       children =
				   [{xmlcdata,
				     <<(translate:translate(Lang,
							    <<"Registration in mod_irc for ">>))/binary,
				       User/binary, "@", Server/binary>>}]},
			#xmlel{name = <<"instructions">>, attrs = [],
			       children =
				   [{xmlcdata,
				     translate:translate(Lang,
							 <<"Enter username, encodings, ports and "
							   "passwords you wish to use for connecting "
							   "to IRC servers">>)}]},
			#xmlel{name = <<"field">>,
			       attrs =
				   [{<<"type">>, <<"text-single">>},
				    {<<"label">>,
				     translate:translate(Lang,
							 <<"IRC Username">>)},
				    {<<"var">>, <<"username">>}],
			       children =
				   [#xmlel{name = <<"value">>, attrs = [],
					   children = [{xmlcdata, Username}]}]},
			#xmlel{name = <<"field">>,
			       attrs = [{<<"type">>, <<"fixed">>}],
			       children =
				   [#xmlel{name = <<"value">>, attrs = [],
					   children =
					       [{xmlcdata,
						 iolist_to_binary(
                                                   io_lib:format(
                                                     translate:translate(
                                                       Lang,
                                                       <<"If you want to specify"
                                                         " different ports, "
                                                         "passwords, encodings "
                                                         "for IRC servers, "
                                                         "fill this list with "
                                                         "values in format "
                                                         "'{\"irc server\", "
                                                         "\"encoding\", port, "
                                                         "\"password\"}'.  "
                                                         "By default this "
                                                         "service use \"~s\" "
                                                         "encoding, port ~p, "
                                                         "empty password.">>),
                                                     [DefaultEncoding,
                                                      ?DEFAULT_IRC_PORT]))}]}]},
			#xmlel{name = <<"field">>,
			       attrs = [{<<"type">>, <<"fixed">>}],
			       children =
				   [#xmlel{name = <<"value">>, attrs = [],
					   children =
					       [{xmlcdata,
						 translate:translate(Lang,
								     <<"Example: [{\"irc.lucky.net\", \"koi8-r\", "
								       "6667, \"secret\"}, {\"vendetta.fef.net\", "
								       "\"iso8859-1\", 7000}, {\"irc.sometestserver.n"
								       "et\", \"utf-8\"}].">>)}]}]},
			#xmlel{name = <<"field">>,
			       attrs =
				   [{<<"type">>, <<"text-multi">>},
				    {<<"label">>,
				     translate:translate(Lang,
							 <<"Connections parameters">>)},
				    {<<"var">>, <<"connections_params">>}],
			       children =
				   lists:map(fun (S) ->
						     #xmlel{name = <<"value">>,
							    attrs = [],
							    children =
								[{xmlcdata, S}]}
					     end,
					     str:tokens(list_to_binary(
                                                          io_lib:format(
                                                            "~p.",
                                                            [conn_params_to_list(
                                                               ConnectionsParams)])),
							<<"\n">>))}]}]}
    end;
get_form(_ServerHost, _Host, _, _, _Lang) ->
    {error, ?ERR_SERVICE_UNAVAILABLE}.

set_data(ServerHost, Host, From, Data) ->
    LServer = jid:nameprep(ServerHost),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:set_data(LServer, Host, From, data_to_binary(From, Data)).

set_form(ServerHost, Host, From, [], Lang, XData) ->
    case {lists:keysearch(<<"username">>, 1, XData),
	  lists:keysearch(<<"connections_params">>, 1, XData)}
	of
      {{value, {_, [Username]}}, {value, {_, Strings}}} ->
	  EncString = lists:foldl(fun (S, Res) ->
					  <<Res/binary, S/binary, "\n">>
				  end,
				  <<"">>, Strings),
	  case erl_scan:string(binary_to_list(EncString)) of
	    {ok, Tokens, _} ->
		case erl_parse:parse_term(Tokens) of
		  {ok, ConnectionsParams} ->
		      case set_data(ServerHost, Host, From,
				    [{username, Username},
				     {connections_params, ConnectionsParams}])
			  of
			{atomic, _} -> {result, []};
			_ -> {error, ?ERRT_NOT_ACCEPTABLE(Lang, <<"Database failure">>)}
		      end;
		  _ -> {error, ?ERRT_NOT_ACCEPTABLE(Lang, <<"Parse error">>)}
		end;
	    _ -> {error, ?ERRT_NOT_ACCEPTABLE(Lang, <<"Scan error">>)}
	  end;
      _ -> {error, ?ERR_NOT_ACCEPTABLE}
    end;
set_form(_ServerHost, _Host, _, _, _Lang, _XData) ->
    {error, ?ERR_SERVICE_UNAVAILABLE}.

get_connection_params(Host, From, IRCServer) ->
    [_ | HostTail] = str:tokens(Host, <<".">>),
    ServerHost = str:join(HostTail, <<".">>),
    get_connection_params(Host, ServerHost, From,
			  IRCServer).

get_default_encoding(ServerHost) ->
    Result = gen_mod:get_module_opt(ServerHost, ?MODULE, default_encoding,
                                    fun iolist_to_binary/1,
                                    ?DEFAULT_IRC_ENCODING),
    ?INFO_MSG("The default_encoding configured for "
	      "host ~p is: ~p~n",
	      [ServerHost, Result]),
    Result.

get_connection_params(Host, ServerHost, From,
		      IRCServer) ->
    #jid{user = User, server = _Server} = From,
    DefaultEncoding = get_default_encoding(ServerHost),
    case get_data(ServerHost, Host, From) of
      error ->
	  {User, DefaultEncoding, ?DEFAULT_IRC_PORT, <<"">>};
      empty ->
	  {User, DefaultEncoding, ?DEFAULT_IRC_PORT, <<"">>};
      Data ->
          {Username, ConnParams} = get_username_and_connection_params(Data),
	  {NewUsername, NewEncoding, NewPort, NewPassword} = case
							       lists:keysearch(IRCServer,
									       1,
									       ConnParams)
								 of
							       {value,
								{_, Encoding,
								 Port,
								 Password}} ->
								   {Username,
								    Encoding,
								    Port,
								    Password};
							       {value,
								{_, Encoding,
								 Port}} ->
								   {Username,
								    Encoding,
								    Port,
								    <<"">>};
							       {value,
								{_,
								 Encoding}} ->
								   {Username,
								    Encoding,
								    ?DEFAULT_IRC_PORT,
								    <<"">>};
							       _ ->
								   {Username,
								    DefaultEncoding,
								    ?DEFAULT_IRC_PORT,
								    <<"">>}
							     end,
	  {iolist_to_binary(NewUsername),
           iolist_to_binary(NewEncoding),
	   if NewPort >= 0 andalso NewPort =< 65535 -> NewPort;
	      true -> ?DEFAULT_IRC_PORT
	   end,
	   iolist_to_binary(NewPassword)}
    end.

adhoc_join(_From, _To,
	   #adhoc_request{action = <<"cancel">>} = Request) ->
    adhoc:produce_response(Request,
			   #adhoc_response{status = canceled});
adhoc_join(From, To,
	   #adhoc_request{lang = Lang, node = _Node,
			  action = _Action, xdata = XData} =
	       Request) ->
    if XData == false ->
	   Form = #xmlel{name = <<"x">>,
			 attrs =
			     [{<<"xmlns">>, ?NS_XDATA},
			      {<<"type">>, <<"form">>}],
			 children =
			     [#xmlel{name = <<"title">>, attrs = [],
				     children =
					 [{xmlcdata,
					   translate:translate(Lang,
							       <<"Join IRC channel">>)}]},
			      #xmlel{name = <<"field">>,
				     attrs =
					 [{<<"var">>, <<"channel">>},
					  {<<"type">>, <<"text-single">>},
					  {<<"label">>,
					   translate:translate(Lang,
							       <<"IRC channel (don't put the first #)">>)}],
				     children =
					 [#xmlel{name = <<"required">>,
						 attrs = [], children = []}]},
			      #xmlel{name = <<"field">>,
				     attrs =
					 [{<<"var">>, <<"server">>},
					  {<<"type">>, <<"text-single">>},
					  {<<"label">>,
					   translate:translate(Lang,
							       <<"IRC server">>)}],
				     children =
					 [#xmlel{name = <<"required">>,
						 attrs = [], children = []}]}]},
	   adhoc:produce_response(Request,
				  #adhoc_response{status = executing,
						  elements = [Form]});
       true ->
	   case jlib:parse_xdata_submit(XData) of
	     invalid ->
		 Txt1 = <<"Incorrect data form">>,
		 {error, ?ERRT_BAD_REQUEST(Lang, Txt1)};
	     Fields ->
		 Channel = case lists:keysearch(<<"channel">>, 1, Fields)
			       of
			     {value, {<<"channel">>, [C]}} -> C;
			     _ -> false
			   end,
		 Server = case lists:keysearch(<<"server">>, 1, Fields)
			      of
			    {value, {<<"server">>, [S]}} -> S;
			    _ -> false
			  end,
		 if Channel /= false, Server /= false ->
			RoomJID = <<Channel/binary, "%", Server/binary, "@",
				    (To#jid.server)/binary>>,
			Invite = #xmlel{name = <<"message">>, attrs = [],
					children =
					    [#xmlel{name = <<"x">>,
						    attrs =
							[{<<"xmlns">>,
							  ?NS_MUC_USER}],
						    children =
							[#xmlel{name =
								    <<"invite">>,
								attrs =
								    [{<<"from">>,
								      jid:to_string(From)}],
								children =
								    [#xmlel{name
										=
										<<"reason">>,
									    attrs
										=
										[],
									    children
										=
										[{xmlcdata,
										  translate:translate(Lang,
												      <<"Join the IRC channel here.">>)}]}]}]},
					     #xmlel{name = <<"x">>,
						    attrs =
							[{<<"xmlns">>,
							  ?NS_XCONFERENCE}],
						    children =
							[{xmlcdata,
							  translate:translate(Lang,
									      <<"Join the IRC channel here.">>)}]},
					     #xmlel{name = <<"body">>,
						    attrs = [],
						    children =
							[{xmlcdata,
							  iolist_to_binary(
                                                            io_lib:format(
                                                              translate:translate(
                                                                Lang,
                                                                <<"Join the IRC channel in this Jabber ID: ~s">>),
                                                              [RoomJID]))}]}]},
			ejabberd_router:route(jid:from_string(RoomJID), From,
					      Invite),
			adhoc:produce_response(Request,
					       #adhoc_response{status =
								   completed});
		    true -> {error, ?ERR_BAD_REQUEST}
		 end
	   end
    end.

adhoc_register(_ServerHost, _From, _To,
	       #adhoc_request{action = <<"cancel">>} = Request) ->
    adhoc:produce_response(Request,
			   #adhoc_response{status = canceled});
adhoc_register(ServerHost, From, To,
	       #adhoc_request{lang = Lang, node = _Node, xdata = XData,
			      action = Action} =
		   Request) ->
    #jid{user = User} = From,
    #jid{lserver = Host} = To,
    if XData == false ->
	   case get_data(ServerHost, Host, From) of
	     error -> Username = User, ConnectionsParams = [];
	     empty -> Username = User, ConnectionsParams = [];
	     Data ->
		 {Username, ConnectionsParams} =
                       get_username_and_connection_params(Data)
	   end,
	   Error = false;
       true ->
	   case jlib:parse_xdata_submit(XData) of
	     invalid ->
		 Txt1 = <<"Incorrect data form">>,
		 Error = {error, ?ERRT_BAD_REQUEST(Lang, Txt1)},
		 Username = false,
		 ConnectionsParams = false;
	     Fields ->
		 Username = case lists:keysearch(<<"username">>, 1,
						 Fields)
				of
			      {value, {<<"username">>, U}} -> U;
			      _ -> User
			    end,
		 ConnectionsParams = parse_connections_params(Fields),
		 Error = false
	   end
    end,
    if Error /= false -> Error;
       Action == <<"complete">> ->
	   case set_data(ServerHost, Host, From,
			 [{username, Username},
			  {connections_params, ConnectionsParams}])
	       of
	     {atomic, _} ->
		 adhoc:produce_response(Request,
					#adhoc_response{status = completed});
	     _ ->
		 Txt2 = <<"Database failure">>,
		 {error, ?ERRT_INTERNAL_SERVER_ERROR(Lang, Txt2)}
	   end;
       true ->
	   Form = generate_adhoc_register_form(Lang, Username,
					       ConnectionsParams),
	   adhoc:produce_response(Request,
				  #adhoc_response{status = executing,
						  elements = [Form],
						  actions =
						      [<<"next">>,
						       <<"complete">>]})
    end.

generate_adhoc_register_form(Lang, Username,
			     ConnectionsParams) ->
    #xmlel{name = <<"x">>,
	   attrs =
	       [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"form">>}],
	   children =
	       [#xmlel{name = <<"title">>, attrs = [],
		       children =
			   [{xmlcdata,
			     translate:translate(Lang, <<"IRC settings">>)}]},
		#xmlel{name = <<"instructions">>, attrs = [],
		       children =
			   [{xmlcdata,
			     translate:translate(Lang,
						 <<"Enter username and encodings you wish "
						   "to use for connecting to IRC servers. "
						   " Press 'Next' to get more fields to "
						   "fill in.  Press 'Complete' to save settings.">>)}]},
		#xmlel{name = <<"field">>,
		       attrs =
			   [{<<"var">>, <<"username">>},
			    {<<"type">>, <<"text-single">>},
			    {<<"label">>,
			     translate:translate(Lang, <<"IRC username">>)}],
		       children =
			   [#xmlel{name = <<"required">>, attrs = [],
				   children = []},
			    #xmlel{name = <<"value">>, attrs = [],
				   children = [{xmlcdata, Username}]}]}]
		 ++
		 generate_connection_params_fields(Lang,
						   ConnectionsParams, 1, [])}.

generate_connection_params_fields(Lang, [], Number,
				  Acc) ->
    Field = generate_connection_params_field(Lang, <<"">>,
					     <<"">>, -1, <<"">>, Number),
    lists:reverse(Field ++ Acc);
generate_connection_params_fields(Lang,
				  [ConnectionParams | ConnectionsParams],
				  Number, Acc) ->
    case ConnectionParams of
      {Server, Encoding, Port, Password} ->
	  Field = generate_connection_params_field(Lang, Server,
						   Encoding, Port, Password,
						   Number),
	  generate_connection_params_fields(Lang,
					    ConnectionsParams, Number + 1,
					    Field ++ Acc);
      {Server, Encoding, Port} ->
	  Field = generate_connection_params_field(Lang, Server,
						   Encoding, Port, <<"">>, Number),
	  generate_connection_params_fields(Lang,
					    ConnectionsParams, Number + 1,
					    Field ++ Acc);
      {Server, Encoding} ->
	  Field = generate_connection_params_field(Lang, Server,
						   Encoding, -1, <<"">>, Number),
	  generate_connection_params_fields(Lang,
					    ConnectionsParams, Number + 1,
					    Field ++ Acc);
      _ -> []
    end.

generate_connection_params_field(Lang, Server, Encoding,
				 Port, Password, Number) ->
    EncodingUsed = case Encoding of
		     <<>> -> get_default_encoding(Server);
		     _ -> Encoding
		   end,
    PortUsedInt = if Port >= 0 andalso Port =< 65535 ->
			 Port;
		     true -> ?DEFAULT_IRC_PORT
		  end,
    PortUsed =
	iolist_to_binary(integer_to_list(PortUsedInt)),
    PasswordUsed = case Password of
		     <<>> -> <<>>;
		     _ -> Password
		   end,
    NumberString =
	iolist_to_binary(integer_to_list(Number)),
    [#xmlel{name = <<"field">>,
	    attrs =
		[{<<"var">>, <<"password", NumberString/binary>>},
		 {<<"type">>, <<"text-single">>},
		 {<<"label">>,
		  iolist_to_binary(
                    io_lib:format(
                      translate:translate(Lang, <<"Password ~b">>),
                      [Number]))}],
	    children =
		[#xmlel{name = <<"value">>, attrs = [],
			children = [{xmlcdata, PasswordUsed}]}]},
     #xmlel{name = <<"field">>,
	    attrs =
		[{<<"var">>, <<"port", NumberString/binary>>},
		 {<<"type">>, <<"text-single">>},
		 {<<"label">>,
		  iolist_to_binary(
                    io_lib:format(translate:translate(Lang, <<"Port ~b">>),
                                  [Number]))}],
	    children =
		[#xmlel{name = <<"value">>, attrs = [],
			children = [{xmlcdata, PortUsed}]}]},
     #xmlel{name = <<"field">>,
	    attrs =
		[{<<"var">>, <<"encoding", NumberString/binary>>},
		 {<<"type">>, <<"list-single">>},
		 {<<"label">>,
		  list_to_binary(
                    io_lib:format(translate:translate(
                                    Lang,
                                    <<"Encoding for server ~b">>),
                                  [Number]))}],
	    children =
		[#xmlel{name = <<"value">>, attrs = [],
			children = [{xmlcdata, EncodingUsed}]}
		 | lists:map(fun (E) ->
				     #xmlel{name = <<"option">>,
					    attrs = [{<<"label">>, E}],
					    children =
						[#xmlel{name = <<"value">>,
							attrs = [],
							children =
							    [{xmlcdata, E}]}]}
			     end,
			     ?POSSIBLE_ENCODINGS)]},
     #xmlel{name = <<"field">>,
	    attrs =
		[{<<"var">>, <<"server", NumberString/binary>>},
		 {<<"type">>, <<"text-single">>},
		 {<<"label">>,
		  list_to_binary(
                    io_lib:format(translate:translate(Lang, <<"Server ~b">>),
                                  [Number]))}],
	    children =
		[#xmlel{name = <<"value">>, attrs = [],
			children = [{xmlcdata, Server}]}]}].

parse_connections_params(Fields) ->
    Servers = lists:flatmap(
                fun({<<"server", Var/binary>>, Value}) ->
                        [{Var, Value}];
                   (_) ->
                        []
                end, Fields),
    Encodings = lists:flatmap(
                  fun({<<"encoding", Var/binary>>, Value}) ->
                          [{Var, Value}];
                     (_) ->
                          []
                  end, Fields),
    Ports = lists:flatmap(
              fun({<<"port", Var/binary>>, Value}) ->
                      [{Var, Value}];
                 (_) ->
                      []
              end, Fields),
    Passwords = lists:flatmap(
                  fun({<<"password", Var/binary>>, Value}) ->
                          [{Var, Value}];
                     (_) ->
                          []
                  end, Fields),
    parse_connections_params(Servers, Encodings, Ports,
			     Passwords).

retrieve_connections_params(ConnectionParams,
			    ServerN) ->
    case ConnectionParams of
      [{ConnectionParamN, ConnectionParam}
       | ConnectionParamsTail] ->
	  if ServerN == ConnectionParamN ->
		 {ConnectionParam, ConnectionParamsTail};
	     ServerN < ConnectionParamN ->
		 {[],
		  [{ConnectionParamN, ConnectionParam}
		   | ConnectionParamsTail]};
	     ServerN > ConnectionParamN -> {[], ConnectionParamsTail}
	  end;
      _ -> {[], []}
    end.

parse_connections_params([], _, _, _) -> [];
parse_connections_params(_, [], [], []) -> [];
parse_connections_params([{ServerN, Server} | Servers],
			 Encodings, Ports, Passwords) ->
    {NewEncoding, NewEncodings} =
	retrieve_connections_params(Encodings, ServerN),
    {NewPort, NewPorts} = retrieve_connections_params(Ports,
						      ServerN),
    {NewPassword, NewPasswords} =
	retrieve_connections_params(Passwords, ServerN),
    [{Server, NewEncoding, NewPort, NewPassword}
     | parse_connections_params(Servers, NewEncodings,
				NewPorts, NewPasswords)].

get_username_and_connection_params(Data) ->
    Username = case lists:keysearch(username, 1, Data) of
                   {value, {_, U}} when is_binary(U) ->
                       U;
                   _ ->
                       <<"">>
               end,
    ConnParams = case lists:keysearch(connections_params, 1, Data) of
                     {value, {_, L}} when is_list(L) ->
                         L;
                     _ ->
                         []
                 end,
    {Username, ConnParams}.

data_to_binary(JID, Data) ->
    lists:map(
      fun({username, U}) ->
              {username, iolist_to_binary(U)};
         ({connections_params, Params}) ->
	      {connections_params,
	       lists:flatmap(
		 fun(Param) ->
			 try
			     [conn_param_to_binary(Param)]
			 catch _:_ ->
				 if JID /= error ->
					 ?ERROR_MSG("failed to convert "
						    "parameter ~p for user ~s",
						    [Param,
						     jid:to_string(JID)]);
				    true ->
					 ?ERROR_MSG("failed to convert "
						    "parameter ~p",
						    [Param])
				 end,
				 []
			 end
		 end, Params)};
         (Opt) ->
              Opt
      end, Data).

conn_param_to_binary({S}) ->
    {iolist_to_binary(S)};
conn_param_to_binary({S, E}) ->
    {iolist_to_binary(S), iolist_to_binary(E)};
conn_param_to_binary({S, E, Port}) when is_integer(Port) ->
    {iolist_to_binary(S), iolist_to_binary(E), Port};
conn_param_to_binary({S, E, Port, P}) when is_integer(Port) ->
    {iolist_to_binary(S), iolist_to_binary(E), Port, iolist_to_binary(P)}.

conn_params_to_list(Params) ->
    lists:map(
      fun({S}) ->
              {binary_to_list(S)};
         ({S, E}) ->
              {binary_to_list(S), binary_to_list(E)};
         ({S, E, Port}) ->
              {binary_to_list(S), binary_to_list(E), Port};
         ({S, E, Port, P}) ->
              {binary_to_list(S), binary_to_list(E),
               Port, binary_to_list(P)}
      end, Params).

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

import_info() ->
    [{<<"irc_custom">>, 4}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:init(LServer, []).

import(LServer, {odbc, _}, DBType, Tab, L) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:init(LServer, Tab, L).

mod_opt_type(access) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(default_encoding) ->
    fun iolist_to_binary/1;
mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(_) ->
    [access, db_type, default_encoding, host, p1db_group].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
