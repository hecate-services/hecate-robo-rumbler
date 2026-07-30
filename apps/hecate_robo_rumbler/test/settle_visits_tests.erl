%% @doc Tests for settling a visit.
%%
%% THE HAZARD THESE EXIST FOR is not that the service crashes. It is that it
%% publishes a complete, plausible row about a DIFFERENT CONTEST than the one a
%% visitor asked for. That has happened four times on this front in one day: a
%% validator comparing a width to itself, a placement 256x outside the arena, a
%% content address with no cross-release guarantee, and a duel run on a geometry
%% measured to produce stalemates. Every one produced full, real-looking output.
%%
%% So most of this file checks DIRECTION and IDENTITY rather than absence of
%% crashes.
%% @end
-module(settle_visits_tests).

-include_lib("eunit/include/eunit.hrl").

%% Eight starts, not eighty. Enough to make a direction unambiguous, fast enough
%% to run in a suite. The full row uses the held-out 80 and takes 13 seconds.
-define(SAMPLE, 8).

%%==============================================================================
%% The field
%%==============================================================================

field_loads_and_every_resident_validates_test() ->
    {ok, Field} = field(),
    ?assertEqual(40, length(Field)),
    %% Boot validation is robo_genome's, so a resident and a visitor are held to
    %% exactly the same contract. Anything else and comparing them means nothing.
    [?assertMatch({ok, _}, robo_genome:validate(G)) || #{genome := G} <- Field],
    %% Content ids are computed from the genome that would actually fight, so
    %% they cannot go stale against it.
    [?assertEqual(robo_genome:id(G), Id) || #{genome := G, id := Id} <- Field].

field_provenance_states_what_it_is_not_test() ->
    {ok, Field} = field(),
    P = resident_field:provenance(Field),
    ?assertEqual(40, maps:get(size, P)),
    ?assertEqual(#{s => 20, l => 10, d => 10}, maps:get(by_arm, P)),
    %% The caveat travels on the wire, because a qualifier that lives only in a
    %% README is a qualifier nobody sees.
    ?assert(byte_size(maps:get(caveat, P)) > 0).

%%==============================================================================
%% DIRECTION. The check that catches a misread seat.
%%==============================================================================

%% If the challenger's outcome were read from the wrong entrant, both of these
%% would report the same direction. They must invert.
stronger_beats_weaker_and_the_inverse_holds_test() ->
    {ok, Field} = field(),
    A = by_seed(2001, Field),
    B = by_seed(2005, Field),
    Fwd = settle_visits:duel(genome(A), B, sample()),
    Rev = settle_visits:duel(genome(B), A, sample()),
    ?assertEqual(maps:get(wins, Fwd), maps:get(losses, Rev)),
    ?assertEqual(maps:get(losses, Fwd), maps:get(wins, Rev)),
    ?assert(maps:get(wins, Fwd) > maps:get(losses, Fwd)).

%% THE STRONGEST CHECK IN THIS FILE. A genome against itself is a mirror match:
%% neither side can out-fight the other, so every match must draw. A misread seat
%% cannot produce this, it produces a sweep.
self_match_is_all_draws_test() ->
    {ok, Field} = field(),
    A = by_seed(2001, Field),
    D = settle_visits:duel(genome(A), A, sample()),
    ?assertEqual(0, maps:get(wins, D)),
    ?assertEqual(0, maps:get(losses, D)),
    ?assertEqual(maps:get(matches, D), maps:get(draws, D)).

%% Both seats of every start, so a seat advantage cannot read as skill.
every_start_is_played_from_both_seats_test() ->
    {ok, Field} = field(),
    D = settle_visits:duel(genome(by_seed(2001, Field)), by_seed(2005, Field), sample()),
    ?assertEqual(?SAMPLE * 2, maps:get(matches, D)),
    ?assertEqual(maps:get(matches, D),
                 maps:get(wins, D) + maps:get(losses, D) + maps:get(draws, D)
                 + maps:get(unplayable, D)).

%%==============================================================================
%% Refusing a visitor
%%==============================================================================

garbage_is_refused_with_a_reason_test() ->
    {ok, Field} = field(),
    ?assertMatch({error, {rejected, _}}, settle_visits:settle(<<"nope">>, Field)),
    ?assertEqual({error, not_a_binary}, settle_visits:settle(nonsense, Field)).

%% A genome of the wrong shape does not crash and does not fight badly: it is
%% refused before a turn is simulated, because robo_net pads a wrong-width input
%% layer in silence and the row would otherwise look real.
wrong_shaped_genome_is_refused_test() ->
    {ok, Field} = field(),
    %% Built BY HAND, because pack/1 refuses to pack an invalid genome. Hand
    %% construction is the truer test: it is exactly what a buggy or hostile
    %% sender puts on the wire, and the decoder has to meet it without help.
    N = robo_net:weight_count([16, 5]),
    Bad = <<"RG", 1:8, 2:16, 16:16/big-unsigned, 5:16/big-unsigned,
            N:32/big-unsigned, 0:(N * 16)>>,
    ?assertMatch({error, {rejected, {wrong_input_width, 16, 17}}},
                 settle_visits:settle(Bad, Field)).

empty_field_is_refused_test() ->
    {ok, Field} = field(),
    #{genome := G} = hd(Field),
    ?assertEqual({error, empty_field}, settle_visits:settle(robo_genome:pack(G), [])).

%%==============================================================================
%% Fixtures
%%==============================================================================

field() -> resident_field:load(priv_path()).

priv_path() -> filename:join(code:priv_dir(hecate_robo_rumbler), "residents.eterm").

sample() -> lists:sublist(robo_starts:split(heldout), ?SAMPLE).

by_seed(Seed, Field) -> hd([R || #{seed := S} = R <- Field, S =:= Seed]).

genome(#{genome := G}) -> G.
