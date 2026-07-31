%% @doc Tests for the archive.
%%
%% THE ARCHIVE'S WORST FAILURE IS NOT LOSING A GENOME, it is handing back bytes
%% that are not what the id names. Everything downstream trusts that id: a
%% published row, a future cross-play matrix, a field built from what arrived. So
%% most of this file is about identity and corruption rather than storage.
%% @end
-module(visit_archive_tests).

-include_lib("eunit/include/eunit.hrl").

%%==============================================================================
%% Storing and retrieving
%%==============================================================================

round_trip_test() ->
    with_dir(fun(Dir) ->
        Bytes = a_genome(),
        {ok, Id} = visit_archive:put_genome(Dir, Bytes),
        ?assertEqual(robo_genome:id(Bytes), Id),
        ?assert(visit_archive:has_genome(Dir, Id)),
        ?assertEqual({ok, Bytes}, visit_archive:get_genome(Dir, Id)),
        ?assertEqual(1, visit_archive:genome_count(Dir))
    end).

missing_genome_is_not_found_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual({error, not_found},
                     visit_archive:get_genome(Dir, crypto:hash(sha256, <<"nothing">>))),
        ?assertNot(visit_archive:has_genome(Dir, crypto:hash(sha256, <<"nothing">>)))
    end).

non_binary_is_refused_test() ->
    with_dir(fun(Dir) -> ?assertEqual({error, not_a_binary},
                                      visit_archive:put_genome(Dir, nonsense)) end).

%%==============================================================================
%% Dedup, which is what makes a flood harmless
%%==============================================================================

%% The same tank arriving many times is ONE entry. That is what makes a flood add
%% samples rather than cost storage, and it is why no rate limit is needed to
%% protect the archive specifically.
duplicate_arrivals_are_one_entry_test() ->
    with_dir(fun(Dir) ->
        Bytes = a_genome(),
        Ids = [element(2, visit_archive:put_genome(Dir, Bytes)) || _ <- lists:seq(1, 50)],
        ?assertEqual(1, length(lists:usort(Ids))),
        ?assertEqual(1, visit_archive:genome_count(Dir))
    end).

different_genomes_are_different_entries_test() ->
    with_dir(fun(Dir) ->
        {ok, A} = visit_archive:put_genome(Dir, a_genome()),
        {ok, B} = visit_archive:put_genome(Dir, another_genome()),
        ?assertNotEqual(A, B),
        ?assertEqual(2, visit_archive:genome_count(Dir))
    end).

%%==============================================================================
%% Corruption. The failure the archive exists to make impossible to miss.
%%==============================================================================

%% Every read re-hashes. A file edited by hand, truncated by a crash, or rotted on
%% disk must be reported and never returned as if it were the genome its name
%% claims.
tampered_file_is_reported_not_returned_test() ->
    with_dir(fun(Dir) ->
        {ok, Id} = visit_archive:put_genome(Dir, a_genome()),
        ok = file:write_file(genome_path(Dir, Id), another_genome()),
        ?assertMatch({error, {corrupt, Id, _Actual}}, visit_archive:get_genome(Dir, Id))
    end).

self_check_finds_the_tampered_one_test() ->
    with_dir(fun(Dir) ->
        {ok, _} = visit_archive:put_genome(Dir, a_genome()),
        {ok, Id} = visit_archive:put_genome(Dir, another_genome()),
        ?assertEqual({ok, 2}, visit_archive:self_check(Dir)),
        ok = file:write_file(genome_path(Dir, Id), <<"rot">>),
        ?assertMatch({corrupt, [_One]}, visit_archive:self_check(Dir))
    end).

%% A duplicate under a colliding id must NOT overwrite. The stored copy is the
%% evidence that something is wrong, and destroying it is the one unrecoverable
%% move. Simulated by planting different bytes under a known id, which is what a
%% collision or an id-computation defect would look like from here.
duplicate_with_different_bytes_does_not_overwrite_test() ->
    with_dir(fun(Dir) ->
        Bytes = a_genome(),
        {ok, Id} = visit_archive:put_genome(Dir, Bytes),
        ok = file:write_file(genome_path(Dir, Id), <<"planted">>),
        ?assertMatch({error, {id_collision, Id, _, _}},
                     visit_archive:put_genome(Dir, Bytes)),
        %% The planted bytes survive: the archive refused rather than repaired.
        ?assertEqual({ok, <<"planted">>}, file:read_file(genome_path(Dir, Id)))
    end).

%%==============================================================================
%% The journal
%%==============================================================================

%% ONE LOG, TWO KINDS OF ENTRY, so a row is attributable to the field it faced by
%% file order alone. No sequence number to get wrong and no clock to disagree
%% about. This is the property a later evolving field depends on entirely.
journal_preserves_order_across_kinds_test() ->
    with_dir(fun(Dir) ->
        ok = visit_archive:append(Dir, {field, #{field_id => <<"f1">>}}),
        ok = visit_archive:append(Dir, {visit, #{challenger => <<"a">>}}),
        ok = visit_archive:append(Dir, {visit, #{challenger => <<"b">>}}),
        ok = visit_archive:append(Dir, {field, #{field_id => <<"f2">>}}),
        ok = visit_archive:append(Dir, {visit, #{challenger => <<"c">>}}),
        {ok, Entries} = visit_archive:journal(Dir),
        ?assertEqual([{field, #{field_id => <<"f1">>}},
                      {visit, #{challenger => <<"a">>}},
                      {visit, #{challenger => <<"b">>}},
                      {field, #{field_id => <<"f2">>}},
                      {visit, #{challenger => <<"c">>}}], Entries),
        %% The attribution the whole design rests on: c faced f2, a and b faced f1.
        ?assertEqual(<<"f2">>, field_facing(<<"c">>, Entries)),
        ?assertEqual(<<"f1">>, field_facing(<<"a">>, Entries))
    end).

empty_journal_is_empty_not_an_error_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual({ok, []}, visit_archive:journal(Dir)),
        ?assertEqual(0, visit_archive:journal_count(Dir))
    end).

unknown_entry_kind_is_refused_test() ->
    with_dir(fun(Dir) ->
        ?assertEqual({error, unknown_entry_kind}, visit_archive:append(Dir, {gossip, #{}}))
    end).

%%==============================================================================
%% Helpers
%%==============================================================================

%% Walk the journal in order, tracking the most recent field. This is the reader
%% the design promises exists; writing it here proves the promise is keepable.
field_facing(Challenger, Entries) -> facing(Challenger, Entries, none).

facing(_C, [], Field) -> Field;
facing(C, [{field, #{field_id := F}} | Rest], _Prev) -> facing(C, Rest, F);
facing(C, [{visit, #{challenger := C}} | _Rest], Field) -> Field;
facing(C, [_Other | Rest], Field) -> facing(C, Rest, Field).

genome_path(Dir, Id) ->
    Hex = binary_to_list(binary:encode_hex(Id)),
    filename:join([Dir, "genomes", string:slice(Hex, 0, 2), Hex ++ ".rg"]).

a_genome() ->
    L = [robo_pilot:inputs(), robo_pilot:outputs()],
    robo_genome:pack({L, lists:duplicate(robo_net:weight_count(L), 0)}).

another_genome() ->
    L = [robo_pilot:inputs(), robo_pilot:outputs()],
    robo_genome:pack({L, lists:duplicate(robo_net:weight_count(L), 7)}).

with_dir(F) ->
    Dir = filename:join(["/tmp", "rumbler_archive_test",
                         integer_to_list(erlang:unique_integer([positive]))]),
    try F(Dir) after file:del_dir_r(Dir) end.
