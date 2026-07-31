%% @doc Tests for the published facts.
%%
%% THE SCHEMA IS THE PUBLIC CONTRACT, so these check its SHAPE rather than the
%% numbers in it. A fact that drifts silently is worse than one that breaks
%% loudly: a subscriber written against last week's shape keeps parsing and
%% quietly reads the wrong field.
%% @end
-module(visit_facts_tests).

-include_lib("eunit/include/eunit.hrl").

%%==============================================================================
%% The wire rules, each from something that went wrong somewhere
%%==============================================================================

%% NO TUPLES AS VALUES, anywhere, at any depth. robo_rumble's internal result
%% carries {genome, Hash} and {script, Kind}, and tuples do not survive the mesh
%% cleanly. This is the check that stops the internal shape leaking out.
no_tuples_anywhere_in_either_fact_test() ->
    {ok, Field} = field(),
    ?assertNot(has_tuple(visit_facts:field_published(Field))),
    ?assertNot(has_tuple(a_visit(Field))).

%% ATOM KEYS ONLY. On the mesh an atom key and a binary key that read the same
%% collapse into one, so a map carrying both loses a field on arrival.
all_keys_are_atoms_test() ->
    {ok, Field} = field(),
    ?assert(keys_are_atoms(visit_facts:field_published(Field))),
    ?assert(keys_are_atoms(a_visit(Field))).

%% Data-derived names travel as BINARIES, never as atoms, so a subscriber is not
%% required to share our atom table and a hostile value cannot grow it.
data_derived_names_are_binaries_test() ->
    {ok, Field} = field(),
    F = visit_facts:field_published(Field),
    [?assert(is_binary(maps:get(arm, R))) || R <- maps:get(residents, F)],
    [?assert(is_binary(maps:get(arm, A))) || A <- maps:get(by_arm, F)],
    V = a_visit(Field),
    ?assert(is_binary(maps:get(split, maps:get(start_set, V)))).

%% Hex, so an id can be quoted in a log line or a bug report without being
%% base16'd first, and so no encoder mistakes a raw hash for text.
ids_are_hex_binaries_test() ->
    V = a_visit(element(2, field())),
    [?assertMatch(<<_:64/binary>>, maps:get(K, V))
     || K <- [challenger_id, field_id, engine_id]].

%%==============================================================================
%% The four identities that make a row reconstructible
%%==============================================================================

%% Everything here is research, so an evolving field is data rather than
%% contamination PROVIDED any row can be tied to the exact contest it describes.
%% That needs all four, on every row.
every_row_carries_its_four_identities_test() ->
    V = a_visit(element(2, field())),
    [?assert(maps:is_key(K, V))
     || K <- [engine_id, wire_version, field_id, start_set]].

%% One comparable value for "which field", derived from the field rather than a
%% version string somebody has to remember to bump.
field_id_is_derived_and_order_independent_test() ->
    {ok, Field} = field(),
    ?assertEqual(visit_facts:field_id(Field),
                 visit_facts:field_id(lists:reverse(Field))),
    ?assertNotEqual(visit_facts:field_id(Field),
                    visit_facts:field_id(tl(Field))).

%% The manifest is published once per field version; a row carries only the id.
%% If a row hauled the residents too, the join would drift the day they differ.
row_does_not_repeat_the_manifest_test() ->
    V = a_visit(element(2, field())),
    ?assertNot(maps:is_key(residents, V)),
    ?assert(maps:is_key(field_id, V)).

%% A scratch namespace by default, because publishing is visible to whatever is
%% subscribed and a shared feed is not a safe default to arrive at by accident.
topic_defaults_to_scratch_test() ->
    ?assertEqual(<<"rumble-scratch/visit">>, visit_facts:topic(visit)),
    ?assertEqual(<<"rumble-scratch/field">>, visit_facts:topic(field)).

%%==============================================================================
%% Helpers
%%==============================================================================

field() -> resident_field:load(filename:join(code:priv_dir(hecate_robo_rumbler),
                                             "residents.eterm")).

%% Two residents, so the suite stays quick; the shape is what is under test.
a_visit(Field) ->
    Small = lists:sublist(Field, 2),
    #{packed := P} = hd(Small),
    {ok, Row} = settle_visits:settle(P, Small),
    visit_facts:visit_settled(Row, Small).

has_tuple(M) when is_map(M) -> lists:any(fun has_tuple/1, maps:values(M));
has_tuple(L) when is_list(L) -> lists:any(fun has_tuple/1, L);
has_tuple(T) when is_tuple(T) -> true;
has_tuple(_Other) -> false.

keys_are_atoms(M) when is_map(M) ->
    lists:all(fun is_atom/1, maps:keys(M))
        andalso lists:all(fun keys_are_atoms/1, maps:values(M));
keys_are_atoms(L) when is_list(L) -> lists:all(fun keys_are_atoms/1, L);
keys_are_atoms(_Other) -> true.
