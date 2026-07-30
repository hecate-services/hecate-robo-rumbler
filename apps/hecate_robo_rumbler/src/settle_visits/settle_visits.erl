%% @doc Settle a visit: a stranger's tank arrives, fights the field, gets a row.
%%
%% THIS EXISTS SO A TANK CAN FIGHT ON A STRANGER'S MACHINE AND THE RESULT IS
%% PUBLISHED. It is the whole point of the service and everything else here is
%% wiring around it.
%%
%% NO MESH IN THIS MODULE, DELIBERATELY. settle/2 takes bytes and returns a
%% result, so the thing worth testing is testable without a realm, a pool or a
%% network. The transport is a thin edge that calls this; when it moves, this
%% does not.
%%
%% THE VISITOR PLAYS THE WHOLE FIELD, not a hand-picked panel, and that is a
%% measured decision rather than a generous one. Phase 0 established that the
%% champions' ranking against the scripted opponent is roughly ORTHOGONAL to
%% their ranking against each other: the strongest cross-play champion of the
%% twenty was not in the top competence tier, and one that was is the weakest of
%% all twenty in tank-versus-tank play. So any small panel chosen on a measured
%% quantity would be close to a random choice with respect to the job it is
%% doing. Playing everyone removes the choice.
%%
%% EVERY PAIRING RUNS OVER THE MEASURED START SET, BOTH SEATS. That is 40
%% residents x 80 held-out starts x 2 seats = 6,400 matches per visit, minutes
%% rather than seconds, and it is the cost of a row that means something. The
%% held-out 80 is chosen so a row is directly comparable with the phase 0
%% cross-play matrix, which was measured on exactly those geometries.
%%
%% Scoring one seat only would report a seat advantage as a skill difference,
%% which is what the phase 0 start generator was corrected for.
-module(settle_visits).

-export([settle/2, duel/2, duel/3]).

%% robo_sim's own cap. A battle reaching it ended by exhaustion, not by a kill.
-define(TURN_CAP, 2000).

%%==============================================================================
%% The visit
%%==============================================================================

%% Bytes in, row out. TOTAL over arbitrary input: this function is the one that
%% meets a stranger, so every rejection is a reason that can be published rather
%% than a crash the service has to survive.
-spec settle(binary(), [resident_field:resident()]) -> {ok, map()} | {error, term()}.
settle(ChallengerBytes, Field) when is_binary(ChallengerBytes) ->
    play(robo_genome:unpack(ChallengerBytes), ChallengerBytes, Field);
settle(_NotBytes, _Field) -> {error, not_a_binary}.

play({error, Why}, _Bytes, _Field) -> {error, {rejected, Why}};
play({ok, _G}, _Bytes, []) -> {error, empty_field};
play({ok, G}, Bytes, Field) ->
    Duels = [duel(G, R) || R <- Field],
    {ok, #{challenger => challenger(G, Bytes),
           field => resident_field:provenance(Field),
           duels => Duels,
           tally => tally(Duels),
           engine => robo_rumble:engine_id()}}.

challenger({L, W} = G, Bytes) ->
    #{id => robo_genome:id(Bytes),
      layers => L,
      weight_count => length(W),
      %% Echoed so a reader can confirm the id names the genome that fought
      %% rather than the frame that arrived. They differ if a frame is ever
      %% re-encoded in transit, and that difference should be visible.
      genome_id => robo_genome:id(G)}.

%%==============================================================================
%% One pairing, both seats
%%==============================================================================

%% THE ENTRANT IDS ARE POSITIONAL, NOT SEMANTIC, AND THAT IS THE WHOLE HAZARD
%% HERE. robo_rumble places entrants by their position in the list, so to play
%% both seats the challenger must enter first in one battle and second in the
%% other. Naming the entrants `challenger' and `resident' would then mean the
%% challenger is the entrant called `resident' in the second battle, and reading
%% the wrong one would attribute the RESIDENT's game to the challenger. Nothing
%% would crash. The row would be complete, plausible, and about a different
%% contest. That is the exact failure shape this front keeps producing, so the
%% seats are called `first' and `second' and the challenger's side is stated
%% explicitly in each.
%%
%% EVERY START IN THE SET, BOTH SEATS. The first version of this ran ONE battle
%% per seat on robo_rumble's circle placement, which for two entrants is exactly
%% colinear and exactly facing at a fixed 300 units: the geometry robo_starts
%% exists to avoid, because an all-mutually-facing set drew 106 of 160 with 70
%% percent censored at the turn cap. It was also not two samples. Both orders ran
%% 696 turns with the corresponding winner, because the seat swap under a circle
%% is a rotation of the same battle. So the row would have been 40 complete,
%% plausible entries measuring who draws head-on.
-spec duel({[non_neg_integer()], [integer()]}, resident_field:resident()) -> map().
duel(Challenger, R) -> duel(Challenger, R, robo_starts:split(heldout)).

-spec duel({[non_neg_integer()], [integer()]}, resident_field:resident(),
           [robo_starts:start()]) -> map().
duel(Challenger, #{genome := Resident} = R, Starts) ->
    Outcomes = lists:append([both_seats(Challenger, Resident, S) || S <- Starts]),
    #{resident => resident_field:describe(R),
      matches => length(Outcomes),
      wins => count(win, Outcomes),
      losses => count(loss, Outcomes),
      draws => count(draw, Outcomes),
      unplayable => count(unplayable, Outcomes),
      %% Turn-cap censoring is reported, never folded into draws. Phase 0 measured
      %% a parity cap share of 0.1625 on this same start set, so a row whose cap
      %% share is far above that is describing a stalemate regime rather than a
      %% skill difference, and a reader must be able to see which.
      capped => count(capped, Outcomes)}.

%% The start is asymmetric, so the two seats are two genuinely different
%% geometries rather than one battle rotated.
both_seats(Challenger, Resident, {AX, AY, AH, BX, BY, BH}) ->
    A = seat(Challenger, Resident, [{AX, AY, AH}, {BX, BY, BH}]),
    B = seat(Resident, Challenger, [{AX, AY, AH}, {BX, BY, BH}]),
    [outcome_of(first, A), outcome_of(second, B)].

seat(First, Second, Placement) ->
    robo_rumble:battle([{first, {genome, First}}, {second, {genome, Second}}],
                       #{placement => Placement}).

%% A battle that refuses to start is reported, never silently scored. The only
%% way it can happen here is a resident failing validation, which boot already
%% ruled out, so this is a guard against a future change rather than a live case.
outcome_of(_Which, {error, Why}) -> #{result => unplayable, reason => Why};
outcome_of(Which, {ok, R}) ->
    Me = seat_of(Which, R),
    #{result => verdict(maps:get(winner, R), Which),
      capped => maps:get(turns, R) >= ?TURN_CAP,
      damage => maps:get(damage, Me),
      survived => maps:get(survived, Me),
      turns => maps:get(turns, R)}.

seat_of(Which, #{standings := S}) ->
    hd([X || X <- S, maps:get(id, X) =:= Which]).

%% DRAWS ARE A REAL OUTCOME AND ARE NOT A LOSS. The engine ends a battle with
%% nobody alive, or with the turn cap reached and both alive, and both are draws.
%% Folding them into losses would flatter every challenger's opponent.
verdict(Which, Which) -> win;
verdict(none, _Which) -> draw;
verdict(_Other, _Which) -> loss.

count(capped, Outcomes) -> length([x || O <- Outcomes, maps:get(capped, O, false)]);
count(What, Outcomes) -> length([x || #{result := R} <- Outcomes, R =:= What]).

%%==============================================================================
%% The row
%%==============================================================================

%% RAW COUNTS AND NO RATING. A rating implies a scalar skill, and this front's
%% open question is precisely whether one exists here. The full row is also what
%% a cycling detector consumes, so the honest report and the scientific datum are
%% the same object, which is what the plan asks for.
tally(Duels) ->
    Sum = fun(K) -> lists:sum([maps:get(K, D) || D <- Duels]) end,
    #{opponents => length(Duels),
      matches => Sum(matches),
      wins => Sum(wins),
      losses => Sum(losses),
      draws => Sum(draws),
      capped => Sum(capped),
      unplayable => Sum(unplayable),
      start_set => start_set_id()}.

%% WHICH GEOMETRIES THIS ROW WAS MEASURED ON, as one comparable value. Two rows
%% built on different start sets are not comparable, and a reader cannot tell
%% from the numbers. robo_starts is a pure function of its index, so the identity
%% is derivable rather than a version string somebody has to remember to bump.
start_set_id() ->
    Starts = robo_starts:split(heldout),
    #{split => heldout,
      count => length(Starts),
      digest => binary:encode_hex(
                  binary:part(
                    crypto:hash(sha256,
                                term_to_binary(Starts, [deterministic, {minor_version, 2}])),
                    0, 8))}.
