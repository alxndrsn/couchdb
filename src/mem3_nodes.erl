% Copyright 2010 Cloudant
% 
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(mem3_nodes).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, 
    code_change/3]).

-export([start_link/0, get_nodelist/0]).

-include("mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

-record(state, {changes_pid, update_seq, nodes}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_nodelist() ->
    gen_server:call(?MODULE, get_nodelist).

init([]) ->
    {Nodes, UpdateSeq} = initialize_nodelist(),
    {Pid, _} = spawn_monitor(fun() -> listen_for_changes(UpdateSeq) end),
    {ok, #state{changes_pid = Pid, update_seq = UpdateSeq, nodes = Nodes}}.

handle_call(get_nodelist, _From, State) ->
    {reply, State#state.nodes, State};
handle_call({add_node, Node}, _From, #state{nodes=Nodes} = State) ->
    gen_event:notify(mem3_events, {add_node, Node}),
    {reply, ok, State#state{nodes = lists:umerge([Node], Nodes)}};
handle_call({remove_node, Node}, _From, #state{nodes=Nodes} = State) ->
    gen_event:notify(mem3_events, {remove_node, Node}),
    {reply, ok, State#state{nodes = lists:delete(Node, Nodes)}};
handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _, _, Pid, Reason}, #state{changes_pid=Pid} = State) ->
    ?LOG_INFO("~p changes listener died ~p", [?MODULE, Reason]),
    StartSeq = State#state.update_seq,
    Seq = case Reason of {seq, EndSeq} -> EndSeq; _ -> StartSeq end,
    timer:send_after(5000, start_listener),
    {noreply, State#state{update_seq = Seq}};
handle_info(start_listener, #state{update_seq = Seq} = State) ->
    {NewPid, _} = spawn_monitor(fun() -> listen_for_changes(Seq) end),
    {noreply, State#state{changes_pid=NewPid}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions

initialize_nodelist() ->
    DbName = couch_config:get("mem3", "nodedb", "nodes"),
    {ok, Db} = ensure_exists(DbName),
    {ok, _, Nodes0} = couch_btree:fold(Db#db.id_tree, fun first_fold/3, [], []),
    % add self if not already present
    case lists:member(node(), Nodes0) of
    true ->
        Nodes = Nodes0;
    false ->
        Doc = #doc{id = couch_util:to_binary(node())},
        {ok, _} = couch_db:update_doc(Db, Doc, []),
        Nodes = [node() | Nodes0]
    end,
    couch_db:close(Db),
    {lists:sort(Nodes), Db#db.update_seq}.

first_fold(#full_doc_info{id = <<"_design/", _/binary>>}, _, Acc) ->
    {ok, Acc};
first_fold(#full_doc_info{deleted=true}, _, Acc) ->
    {ok, Acc};
first_fold(#full_doc_info{id=Id}, _, Acc) ->
    {ok, [mem3_util:to_atom(Id) | Acc]}.

listen_for_changes(Since) ->
    DbName = ?l2b(couch_config:get("mem3", "nodedb", "nodes")),
    {ok, Db} = ensure_exists(DbName),
    Args = #changes_args{
        feed = "continuous",
        since = Since,
        heartbeat = true,
        include_docs = true
    },
    ChangesFun = couch_changes:handle_changes(Args, nil, Db),
    ChangesFun(fun changes_callback/2).

ensure_exists(DbName) when is_list(DbName) ->
    ensure_exists(list_to_binary(DbName));
ensure_exists(DbName) ->
    Options = [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}],
    case couch_db:open(DbName, Options) of
    {ok, Db} ->
        {ok, Db};
    _ -> 
        couch_server:create(DbName, Options)
    end.

changes_callback(start, _) ->
    {ok, nil};
changes_callback({stop, EndSeq}, _) ->
    exit({seq, EndSeq});
changes_callback({change, {Change}, _}, _) ->
    Node = couch_util:get_value(<<"id">>, Change),
    case Node of <<"_design/", _/binary>> -> ok; _ ->
        case couch_util:get_value(deleted, Change, false) of
        false ->
            gen_server:call(?MODULE, {add_node, mem3_util:to_atom(Node)});
        true ->
            gen_server:call(?MODULE, {remove_node, mem3_util:to_atom(Node)})
        end
    end,
    {ok, couch_util:get_value(<<"seq">>, Change)};
changes_callback(timeout, _) ->
    {ok, nil}.
