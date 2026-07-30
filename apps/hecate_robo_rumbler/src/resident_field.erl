%% @doc The resident field: the trained tanks a visitor comes to fight.
%%
%% THIS EXISTS SO A VISITOR HAS SOMETHING WORTH FIGHTING. Scripted bots alone
%% would tell a visitor nothing about how it fares against a trained network,
%% which is the only interesting question.
%%
%% Forty champions, evolved during Robo Rumble phase 0 and shipped as data in
%% priv/residents.eterm. About 23 KB, because a trained tank is 577 bytes.
%%
%% EVERY RESIDENT IS VALIDATED AT BOOT, not on first use. A resident that fails
%% the wire contract is a broken build, and it should stop the service starting
%% rather than surface as a strange result during someone's visit. The genomes
%% are stored as {Layers, Weights} and packed here, so the content id a published
%% result carries is always COMPUTED from the genome that actually fought and can
%% never go stale against it.
%%
%% THE FIELD IS NOT A NEUTRAL SAMPLE AND THE MODULE SAYS SO OUT LOUD, because a
%% result read as "beat the field" will otherwise be read as "beat tanks in
%% general". Twenty come from one optimiser on one topology, ten have no hidden
%% layer, and ten were trained against a single opponent rather than the full
%% ladder. They are diverse and real; they are not a random draw from the space
%% of tanks. provenance/0 puts that on the wire rather than in a comment.
-module(resident_field).

-export([load/0, load/1, all/1, size/1, provenance/1, describe/1]).

-type resident() :: #{id := binary(),
                      arm := atom(),
                      seed := integer(),
                      genome := {[non_neg_integer()], [integer()]},
                      packed := binary(),
                      train_fitness := number()}.
-export_type([resident/0]).

%%==============================================================================
%% Loading
%%==============================================================================

-spec load() -> {ok, [resident()]} | {error, term()}.
load() -> load(default_path()).

%% Total over a bad file, because a service that crashes in its supervisor's
%% init with a badmatch tells an operator nothing. Every failure names what was
%% wrong with which resident.
-spec load(file:filename_all()) -> {ok, [resident()]} | {error, term()}.
load(Path) -> from_terms(file:consult(Path), Path).

from_terms({error, Why}, Path) -> {error, {unreadable_field, Path, Why}};
from_terms({ok, []}, Path) -> {error, {empty_field, Path}};
from_terms({ok, Terms}, _Path) -> admit(Terms, []).

admit([], Acc) -> {ok, lists:reverse(Acc)};
admit([T | Rest], Acc) -> admit_one(T, Rest, Acc, build(T)).

admit_one(_T, Rest, Acc, {ok, R}) -> admit(Rest, [R | Acc]);
admit_one(T, _Rest, _Acc, {error, Why}) -> {error, {bad_resident, label(T), Why}}.

%% THE VALIDATION IS robo_genome's, not a second copy of it. A resident and a
%% visitor are held to exactly the same contract, which is the only way a result
%% comparing them means anything.
build(#{arm := Arm, seed := Seed, layers := L, weights := W} = T) ->
    packed(Arm, Seed, {L, W}, T, robo_genome:validate({L, W}));
build(_Other) -> {error, malformed_entry}.

packed(Arm, Seed, G, T, {ok, G}) ->
    Bin = robo_genome:pack(G),
    {ok, #{id => robo_genome:id(Bin),
           arm => Arm,
           seed => Seed,
           genome => G,
           packed => Bin,
           train_fitness => maps:get(train_fitness, T, 0)}};
packed(_Arm, _Seed, _G, _T, {error, _} = E) -> E.

label(#{arm := A, seed := S}) -> {A, S};
label(_Other) -> unlabelled.

default_path() ->
    filename:join(code:priv_dir(hecate_robo_rumbler), "residents.eterm").

%%==============================================================================
%% Reading the field
%%==============================================================================

-spec all([resident()]) -> [resident()].
all(Field) -> Field.

-spec size([resident()]) -> non_neg_integer().
size(Field) -> length(Field).

%% WHAT A READER NEEDS TO NOT OVER-READ A RESULT. Carried on the wire with every
%% published visit, because the composition of the field is the single largest
%% qualifier on what beating it means, and a qualifier that lives only in a
%% README is a qualifier nobody sees.
-spec provenance([resident()]) -> map().
provenance(Field) ->
    #{size => length(Field),
      by_arm => counts(Field),
      source => <<"Robo Rumble phase 0 champion archive (faber-programmes, "
                  "exp066_competence_floor)">>,
      caveat => <<"Not a neutral sample: 20 seeds of one optimiser on one "
                  "topology, 10 with no hidden layer, 10 trained against a "
                  "single opponent rather than the full ladder.">>}.

counts(Field) -> lists:foldl(fun tally_arm/2, #{}, Field).

tally_arm(#{arm := A}, Acc) -> maps:update_with(A, fun bump/1, 1, Acc).

bump(N) -> N + 1.

-spec describe(resident()) -> map().
describe(#{id := Id, arm := Arm, seed := Seed, genome := {L, _W}}) ->
    #{id => Id, arm => Arm, seed => Seed, layers => L}.
