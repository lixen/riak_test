%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%%% @copyright (C) 2015, Basho Technologies
%%% @doc
%%% riak_test for riak_kv_sweeper and 
%%%
%%% Verify that the sweeper doesn't reap until we set a short grace period
%%%
%%% @end

-module(verify_sweep_reaper).
-behavior(riak_test).
-export([confirm/0]).

-include_lib("eunit/include/eunit.hrl").

-define(NUM_NODES, 1).
-define(NUM_KEYS, 1000).
-define(BUCKET, <<"test_bucket">>).
-define(N_VAL, 3).
-define(WAIT_FOR_SWEEP, 15000).

confirm() ->
    Config = [{riak_core, 
               [{ring_creation_size, 4}
               ]},
              {riak_kv,
               [{delete_mode, keep},
                {reap_sweep_interval, 5},
                {sweep_tick, 1000},       %% Speed up sweeping
                {storage_backend, riak_kv_memory_backend},
                {anti_entropy, {off, []}}
               ]}
             ],

    Nodes = rt:build_cluster(1, Config),
    [Client] = create_pb_clients(Nodes),
    KV1 = test_data(1, 1000),
    write_data(Client, KV1),
    delete_keys(Client, KV1),
    wait_for_sweep(),

    false = check_reaps(Client, KV1),
    disable_sweep_scheduling(Nodes),
    set_tombstone_grace(Nodes, 5),
    false = check_reaps(Client, KV1),
    enable_sweep_scheduling(Nodes),

    %% Write key.
    KV2 = test_data(1001, 2000),
    write_data(Client, KV2),
    delete_keys(Client, KV2),
    wait_for_sweep(),
    true = check_reaps(Client, KV2),
    true = check_reaps(Client, KV1),


    disable_sweep_scheduling(Nodes),
    KV3 = test_data(2001, 2001),
    write_data(Client, KV3, [{n_val, 1}]),
    {PNuke, NNuke} = choose_partition_to_nuke(hd(Nodes), ?BUCKET, KV3),
    restart_vnode(NNuke, riak_kv, PNuke),
    manual_sweep(NNuke, PNuke),
    wait_for_sweep(5000),
    true = check_reaps(Client, KV3),


    pass.

wait_for_sweep() ->
    wait_for_sweep(?WAIT_FOR_SWEEP).

wait_for_sweep(WaitTime) ->
    lager:info("Wait for sweep ~p s", [WaitTime]),
    timer:sleep(WaitTime).

write_data(Client, KVs) ->
    lager:info("Writing data ~p keys", [length(KVs)]),
    write_data(Client, KVs, []).
write_data(Client, KVs, Opts) ->
    [begin
         O = riakc_obj:new(?BUCKET, K, V),
         ?assertMatch(ok, riakc_pb_socket:put(Client, O, Opts))
     end || {K, V} <- KVs],
    ok.
test_data(Start, End) ->
    Keys = [to_key(N) || N <- lists:seq(Start, End)],
    [{K, K} || K <- Keys].

to_key(N) ->
    list_to_binary(io_lib:format("K~4..0B", [N])).

delete_keys(Client, KVs) ->
    lager:info("Delete data ~p keys", [length(KVs)]),
    [{delete_key(Client, K)}  || {K, _V} <- KVs].
delete_key(Client, Key) ->
    riakc_pb_socket:delete(Client, ?BUCKET, Key).


check_reaps(Client, KVs) ->
    lager:info("Check data ~p keys", [length(KVs)]),
    Results = [check_reap(Client, K)|| {K, _V} <- KVs],
    Reaped = length([ true || true <- Results]),
    lager:info("Reaped ~p", [Reaped]),
    Reaped == length(KVs).

check_reap(Client, Key) ->
    case riakc_pb_socket:get(Client, ?BUCKET, Key, [deletedvclock]) of
        {error, notfound, _} ->
            false;
        {error, notfound} ->
            true
    end.

%%% Client/Key ops
create_pb_clients(Nodes) ->
    [begin
         C = rt:pbc(N),
         riakc_pb_socket:set_options(C, [queue_if_disconnected]),
         C
     end || N <- Nodes].

set_tombstone_grace(Nodes, Time) ->
    lager:info("set_tombstone_grace ~p s ", [Time]),
    rpc:multicall(Nodes, application, set_env, [riak_kv, tombstone_grace_period,Time]).

disable_sweep_scheduling(Nodes) ->
    rpc:multicall(Nodes, riak_kv_sweeper, disable_sweep_scheduling, []).

enable_sweep_scheduling(Nodes) ->
    rpc:multicall(Nodes, riak_kv_sweeper, enable_sweep_scheduling, []).

restart_vnode(Node, Service, Partition) ->
    VNodeName = list_to_atom(atom_to_list(Service) ++ "_vnode"),
    {ok, Pid} = rpc:call(Node, riak_core_vnode_manager, get_vnode_pid,
                         [Partition, VNodeName]),
    ?assert(rpc:call(Node, erlang, exit, [Pid, kill_for_test])),
    Mon = monitor(process, Pid),
    receive
        {'DOWN', Mon, _, _, _} ->
            ok
    after
        rt_config:get(rt_max_wait_time) ->
            lager:error("VNode for partition ~p did not die, the bastard",
                        [Partition]),
            ?assertEqual(vnode_killed, {failed_to_kill_vnode, Partition})
    end,
    {ok, NewPid} = rpc:call(Node, riak_core_vnode_manager, get_vnode_pid,
                            [Partition, VNodeName]),
    lager:info("Vnode for partition ~p restarted as ~p",
               [Partition, NewPid]).
    
get_preflist(Node, B, K) ->
    DocIdx = rpc:call(Node, riak_core_util, chash_key, [{B, K}]),
    PlTagged = rpc:call(Node, riak_core_apl, get_primary_apl, [DocIdx, ?N_VAL, riak_kv]),
    Pl = [E || {E, primary} <- PlTagged],
    Pl.

acc_preflists(Pl, PlCounts) ->
    lists:foldl(fun(Idx, D) ->
                        dict:update(Idx, fun(V) -> V+1 end, 0, D)
                end, PlCounts, Pl).

choose_partition_to_nuke(Node, Bucket, KVs) ->
    Preflists = [get_preflist(Node, Bucket, K) || {K, _} <- KVs],
    PCounts = lists:foldl(fun acc_preflists/2, dict:new(), Preflists),
    CPs = [{C, P} || {P, C} <- dict:to_list(PCounts)],
    {_, MaxP} = lists:max(CPs),
    MaxP.

manual_sweep(Node, Partition) ->
   rpc:call(Node, riak_kv_sweeper, sweep, [Partition]).


