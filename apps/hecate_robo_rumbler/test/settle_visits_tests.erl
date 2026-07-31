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

%% THE STRONGEST CHECK IN THIS FILE, AND THE FIRST VERSION OF IT WAS MEASURING
%% THE WRONG THING. It asserted a self-match is ALL DRAWS, which passed and was an
%% artifact: the engine dependency was stale, silently ignored the placement
%% option, and ran every duel on the circle. Two entrants on a circle are exactly
%% symmetric, so identical genomes could only draw. The test was evidence that the
%% geometry was symmetric, not that the seats were read correctly.
%%
%% On the real asymmetric start set the invariant is BALANCE, not draws. Each start
%% is played from both seats, and the two seats are the same battle with the labels
%% swapped: whoever wins from position one wins in both, so the challenger takes
%% exactly one win and one loss per start. Measured: 8 wins, 8 losses, 0 draws over
%% 16 matches.
%%
%% It still catches the failure it was written for. A misread seat gives 16-0 or
%% 0-16, never a balance, and unlike the old version it cannot be satisfied by an
%% accidentally symmetric geometry.
self_match_is_exactly_balanced_test() ->
    {ok, Field} = field(),
    A = by_seed(2001, Field),
    D = settle_visits:duel(genome(A), A, sample()),
    ?assertEqual(maps:get(wins, D), maps:get(losses, D)),
    ?assertEqual(maps:get(matches, D),
                 maps:get(wins, D) + maps:get(losses, D) + maps:get(draws, D)),
    %% Not vacuous: a genome that never fought would also balance at zero.
    ?assert(maps:get(wins, D) > 0).

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

%%==============================================================================
%% The compute budget
%%==============================================================================

%% A GENOME CAN BE PERFECTLY LEGAL AND STILL UNAFFORDABLE. The format's cap says
%% what a genome may be; this says what this host will spend on one visit, which
%% the format cannot know because it depends on the field size and the start set.
%% Without it a frame that passes every validation costs roughly fifty minutes.
oversized_but_legal_genome_is_refused_test() ->
    {ok, Field} = field(),
    %% 2,305 weights: comfortably inside the format cap of 65,536, and 14.7M
    %% weight-evaluations for a full row against a 40-strong field, which is not.
    Big = [robo_pilot:inputs(), 100, robo_pilot:outputs()],
    N = robo_net:weight_count(Big),
    %% Legal by the wire format.
    ?assertMatch({ok, _}, robo_genome:validate({Big, lists:duplicate(N, 0)})),
    %% And refused by the service, with the arithmetic in the reason.
    ?assertMatch({error, {rejected, {over_visit_budget, _Cost, _Budget, N}}},
                 settle_visits:settle(robo_genome:pack({Big, lists:duplicate(N, 0)}),
                                      Field)).

%% The residents themselves must be affordable, or the service ships unable to
%% run its own field.
every_resident_is_within_the_budget_test() ->
    {ok, Field} = field(),
    [?assertMatch({ok, _}, settle_visits:settle(P, [hd(Field)]))
     || #{packed := P} <- lists:sublist(Field, 3)].
