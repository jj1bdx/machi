%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.  All Rights Reserved.
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

-module(machi_merkle_tree_test).
-compile([export_all]).

-include("machi_merkle_tree.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(GAP_CHANCE, 0.10).

%% unit tests
basic_test() ->
    random:seed(os:timestamp()),
    Fsz = choose_size() * 1024,
    Filesize = max(Fsz, 10*1024*1024),
    ChunkSize = max(1048576, Filesize div 100),
    N = make_leaf_nodes(Filesize),
    D0 = #naive{ leaves = N, chunk_size = ChunkSize, recalc = true },
    T1 = machi_merkle_tree:build_tree(D0),

    D1 = #naive{ leaves = tl(N), chunk_size = ChunkSize, recalc = true },
    T2 = machi_merkle_tree:build_tree(D1),

    ?assertNotEqual(T1#naive.root, T2#naive.root),
    ?assertEqual(true, length(machi_merkle_tree:naive_diff(T1, T2)) == 1
                       orelse
                       Filesize > ChunkSize).


make_leaf_nodes(Filesize) ->
    lists:reverse(
      lists:foldl(fun(T, Acc) -> machi_merkle_tree:update_acc(T, Acc) end, 
                  [], 
                  generate_offsets(Filesize, 1024, []))
     ).

choose_int(Factor) ->
    random:uniform(1024*Factor).

small_int() ->
    choose_int(10).

medium_int() ->
    choose_int(1024).

large_int() ->
    choose_int(4096).

generate_offsets(Filesize, Current, Acc) when Current < Filesize ->
    Length0 = choose_size(),

    Length = case Length0 + Current > Filesize of
                 false -> Length0;
                  true -> Filesize - Current
    end,
    Data = term_to_binary(os:timestamp()),
    Checksum = machi_util:make_tagged_csum(client_sha, machi_util:checksum_chunk(Data)),
    Gap = maybe_gap(random:uniform()),
    generate_offsets(Filesize, Current + Length + Gap, [ {Current, Length, Checksum} | Acc ]);
generate_offsets(_Filesize, _Current, Acc) ->
    lists:reverse(Acc).


random_from_list(L) ->
    N = random:uniform(length(L)),
    lists:nth(N, L).

choose_size() ->
    F = random_from_list([fun small_int/0, fun medium_int/0, fun large_int/0]),
    F().

maybe_gap(Chance) when Chance < ?GAP_CHANCE ->
    choose_size();
maybe_gap(_) -> 0.

%% Define or remove these ifdefs if benchmarking is desired.
-ifdef(BENCH).
generate_offsets(FH, Filesize, Current, Acc) when Current < Filesize ->
    Length0 = choose_size(),

    Length = case Length0 + Current > Filesize of
                 false -> Length0;
                  true -> Filesize - Current
    end,
    {ok, Data} = file:pread(FH, Current, Length),
    Checksum = machi_util:make_tagged_csum(client_sha, machi_util:checksum_chunk(Data)),
    Gap = maybe_gap(random:uniform()),
    generate_offsets(FH, Filesize, Current + Length + Gap, [ {Current, Length, Checksum} | Acc ]);
generate_offsets(_FH, _Filesize, _Current, Acc) ->
    lists:reverse(Acc).

make_offsets_from_file(Filename) ->
    {ok, Info} = file:read_file_info(Filename),
    Filesize = Info#file_info.size,
    {ok, FH} = file:open(Filename, [read, raw, binary]),
    Offsets = generate_offsets(FH, Filesize, 1024, []),
    file:close(FH),
    Offsets.

choose_filename() ->
    random_from_list([
        "def^c5ea7511-d649-47d6-a8c3-2b619379c237^1",
        "jkl^b077eff7-b2be-4773-a73f-fea4acb8a732^1",
        "stu^553fa47a-157c-4fac-b10f-2252c7d8c37a^1",
        "vwx^ae015d68-7689-4c9f-9677-926c6664f513^1",
        "yza^4c784dc2-19bf-4ac6-91f6-58bbe5aa88e0^1"
                     ]).


make_csum_file(DataDir, Filename, Offsets) ->
    Path = machi_util:make_checksum_filename(DataDir, Filename),
    filelib:ensure_dir(Path),
    {ok, MC} = machi_csum_table:open(Path, []),
    lists:foreach(fun({Offset, Size, Checksum}) -> 
                    machi_csum_table:write(MC, Offset, Size, Checksum) end,
                  Offsets),
    machi_csum_table:close(MC).


test() -> 
    test(100).

test(N) ->
    {ok, F} = file:open("results.txt", [raw, write]),
    lists:foreach(fun(X) -> format_and_store(F, run_test(X)) end, lists:seq(1, N)).

format_and_store(F, {OffsetNum, {MTime, MSize}, {NTime, NSize}}) ->
    S = io_lib:format("~w\t~w\t~w\t~w\t~w\n", [OffsetNum, MTime, MSize, NTime, NSize]),
    ok = file:write(F, S).

run_test(C) ->
    random:seed(os:timestamp()),
    OffsetFn = "test/" ++ choose_filename(),
    O = make_offsets_from_file(OffsetFn),
    Fn = "csum_" ++ integer_to_list(C),
    make_csum_file(".", Fn, O),

    Osize = length(O),

    {MTime, {ok, M}} = timer:tc(fun() -> machi_merkle_tree:open(Fn, ".", merklet) end),
    {NTime, {ok, N}} = timer:tc(fun() -> machi_merkle_tree:open(Fn, ".", naive) end),

    ?assertEqual(Fn, machi_merkle_tree:filename(M)),
    ?assertEqual(Fn, machi_merkle_tree:filename(N)),

    MTree = machi_merkle_tree:tree(M),
    MSize = byte_size(term_to_binary(MTree)),

    NTree = machi_merkle_tree:tree(N),
    NSize = byte_size(term_to_binary(NTree)),

    ?assertEqual(same, machi_merkle_tree:diff(N, N)),
    ?assertEqual(same, machi_merkle_tree:diff(M, M)),
    {Osize, {MTime, MSize}, {NTime, NSize}}.

torture_test(C) ->
    Results = [ run_torture_test() || _ <- lists:seq(1, C) ],
    {ok, F} = file:open("torture_results.txt", [raw, write]),
    lists:foreach(fun({MSize, MTime, NSize, NTime}) ->
                      file:write(F, io_lib:format("~p\t~p\t~p\t~p\n",
                                                [MSize, MTime, NSize, NTime]))
                  end, Results),
    ok = file:close(F).

run_torture_test() ->
    {NTime, N} = timer:tc(fun() -> naive_torture() end), 

    MSize = byte_size(term_to_binary(M)),
    NSize = byte_size(term_to_binary(N)),

    {MSize, MTime, NSize, NTime}.

naive_torture() ->
    N = lists:foldl(fun(T, Acc) -> machi_merkle_tree:update_acc(T, Acc) end, [], torture_generator()),
    T = #naive{ leaves = lists:reverse(N), chunk_size = 10010, recalc = true },
    machi_merkle_tree:build_tree(T).

torture_generator() ->
    [ {O, 1, crypto:hash(sha, term_to_binary(now()))} || O <- lists:seq(1024, 1000000) ].
-endif. % BENCH
