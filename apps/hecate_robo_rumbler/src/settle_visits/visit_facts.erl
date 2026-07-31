%% @doc What goes on the wire: two facts, with an explicit schema.
%%
%% THESE ARE INTEGRATION FACTS, NOT DOMAIN EVENTS. The service holds no store at
%% v1, so there are no domain events to firehose. When a ledger arrives, its
%% events stay internal and a process manager decides which of them become facts.
%%
%% THE SCHEMA IS DECLARED HERE AND NOWHERE ELSE. Publishing robo_rumble's internal
%% result map would have made the public record "whatever the module returned",
%% which drifts silently every time the module changes and pins nothing for a
%% reader. Worse, that map carries Erlang TUPLES as values, `{genome, Hash}' and
%% `{script, Kind}', and tuples do not survive the mesh cleanly.
%%
%% THREE WIRE RULES, EACH FROM SOMETHING THAT ALREADY WENT WRONG SOMEWHERE:
%%
%%   NO TUPLES AS VALUES. Flattened into named fields instead.
%%
%%   ATOM KEYS ONLY, NEVER MIXED WITH BINARY KEYS OF THE SAME NAME. On the mesh an
%%   atom key, a binary key and a text-tuple key that read the same collapse into
%%   ONE key, so a map carrying both loses a field on arrival. That cost another
%%   project months.
%%
%%   IDS AS HEX BINARIES, not raw 32-byte hashes. A reader quoting an id in a bug
%%   report, a URL or a log line should not have to base16 it first, and raw
%%   binary hashes invite an encoder somewhere to treat them as text.
%%
%% WHAT MAKES AN UNCONTROLLED FUTURE RECONSTRUCTIBLE. Everything is research here,
%% so a resident field that evolves is data rather than contamination, PROVIDED
%% any row can be tied back to the exact contest it describes. That needs four
%% identities on every row: which engine, which wire format, which field, and
%% which start set. All four are below, and the field manifest is published once
%% per field version rather than repeated in every row.
-module(visit_facts).

-export([field_published/1, visit_started/2, visit_settled/2,
         duel_featured/3, field_id/1, topic/1]).

%% The schema version of the FACTS, which is not the wire version of a genome.
%% They change for different reasons and conflating them would force a needless
%% break on one side whenever the other moved.
-define(FACT_VERSION, 1).

%%==============================================================================
%% Topics
%%==============================================================================

%% A SCRATCH NAMESPACE UNTIL SOMEONE DECIDES OTHERWISE. Publishing is visible to
%% whatever is subscribed, so the default is deliberately not a shared society
%% feed. Override with HECATE_RUMBLE_NS.
-spec topic(field | visit | challenge | arrival | duel) -> binary().
topic(What) -> <<(namespace())/binary, "/", (leaf(What))/binary>>.

leaf(field) -> <<"field">>;
leaf(visit) -> <<"visit">>;
%% Arrivals, separate from results, so a spectator wanting liveness does not have
%% to subscribe to every settled row to learn that something is happening.
leaf(arrival) -> <<"arrival">>;
%% One watchable duel per visit, carrying the genomes rather than frames.
leaf(duel) -> <<"duel">>;
%% Where a visitor sends a tank. Separate from where results go, so a subscriber
%% wanting results does not also receive every challenge.
leaf(challenge) -> <<"challenge">>.

namespace() ->
    case os:getenv("HECATE_RUMBLE_NS") of
        S when is_list(S), S =/= "" -> unicode:characters_to_binary(S);
        _Unset -> <<"rumble-scratch">>
    end.

%%==============================================================================
%% field_published
%%==============================================================================

%% WHO A VISITOR WILL FACE, published once per field version. Rows then carry only
%% `field_id' and a reader joins, instead of every row hauling forty manifests.
-spec field_published([resident_field:resident()]) -> map().
field_published(Field) ->
    P = resident_field:provenance(Field),
    #{type => field_published,
      fact_version => ?FACT_VERSION,
      field_id => field_id(Field),
      size => maps:get(size, P),
      source => maps:get(source, P),
      %% Travels with the manifest because the composition of the field is the
      %% largest qualifier on what beating it means.
      caveat => maps:get(caveat, P),
      by_arm => arm_counts(P),
      residents => [resident(R) || R <- Field]}.

resident(#{id := Id, arm := Arm, seed := Seed, genome := {L, W}}) ->
    #{resident_id => hex(Id),
      arm => atom_to_binary(Arm, utf8),
      seed => Seed,
      layers => L,
      weight_count => length(W)}.

%% by_arm is a map keyed by arm, and arms are atoms. Rendered as a LIST of flat
%% maps so no atom that came from data ends up as a wire key, which is how a
%% schema quietly becomes open-ended.
arm_counts(P) ->
    [#{arm => atom_to_binary(A, utf8), count => N}
     || {A, N} <- lists:sort(maps:to_list(maps:get(by_arm, P)))].

%% ONE COMPARABLE VALUE FOR "WHICH FIELD". A hash over the sorted resident ids, so
%% it is derived from the field itself rather than a version string somebody has
%% to remember to bump. Sorted, so the same residents in a different order are
%% the same field.
-spec field_id([resident_field:resident()]) -> binary().
field_id(Field) ->
    Ids = lists:sort([Id || #{id := Id} <- Field]),
    hex(crypto:hash(sha256, iolist_to_binary(Ids))).

%%==============================================================================
%% visit_started
%%
%% A CHALLENGER HAS ARRIVED AND IS FIGHTING NOW. Tiny, one per visit, published
%% before the battle rather than after, because the whole point is that a site can
%% say "someone is fighting right now" at the moment it becomes true. A row
%% arrives thirteen seconds later; liveness cannot wait for it.
%%==============================================================================

-spec visit_started(binary(), [resident_field:resident()]) -> map().
visit_started(ChallengerBytes, Field) ->
    #{type => visit_started,
      fact_version => ?FACT_VERSION,
      challenger_id => hex(robo_genome:id(ChallengerBytes)),
      field_id => field_id(Field),
      opponents => length(Field)}.

%%==============================================================================
%% duel_featured
%%
%% ONE WATCHABLE BATTLE PER VISIT, AND IT CARRIES GENOMES RATHER THAN FRAMES.
%%
%% A visit is 6,400 battles of roughly 200 turns: about 1.28 MILLION frames, some
%% 93 MB, produced in the thirteen seconds the row takes. That is a firehose on a
%% shared realm, for one visitor. And a battle computes in about two milliseconds,
%% so there is no real time to stream: anything a person watches is a replay
%% slowed to human speed either way.
%%
%% Since the engine is deterministic, measured byte-identical across two machines,
%% the two genomes and a start index ARE the frames, compressed about sixty to
%% one. A spectator regenerates them by calling the same engine. Publishing frames
%% would ship 17 KB to convey what 1.2 KB conveys exactly, and would make watching
%% depend on the rumbler having published rather than on anyone being able to
%% replay a battle they can name.
%%
%% THIS REPUBLISHES A VISITOR'S GENOME and that is a real disclosure, not a
%% detail. A sender must be told before they send, because "we ran your tank" and
%% "we published your tank for anyone to study and counter" are different deals.
%%==============================================================================

-spec duel_featured(map(), [resident_field:resident()], binary()) -> map() | none.
duel_featured(Row, Field, ChallengerBytes) ->
    pick(maps:get(duels, Row, []), Field, ChallengerBytes).

pick([], _Field, _Bytes) -> none;
pick(Duels, Field, Bytes) -> featured(most_contested(Duels), Field, Bytes).

%% The best battle across the whole row: DECIDED FIRST, longest second.
%%
%% Ranking by length alone does not find the closest fight, it finds the most
%% stalemated one, because a battle that reaches the turn cap is by definition
%% the longest there can be. Both ranks had this bug and fixing only the
%% per-pairing one would have left it here: a capped battle from any pairing
%% would still have beaten every decided battle in the row.
%%
%% Deterministic, so the featured duel is reproducible from the same inputs.
most_contested(Duels) ->
    Scored = [{maps:get(decided, L, false), maps:get(turns, L, 0), D, L}
              || D <- Duels, (L = maps:get(longest, D, none)) =/= none],
    top(lists:reverse(lists:sort(fun by_quality/2, Scored))).

by_quality({D1, T1, _, _}, {D2, T2, _, _}) -> {D1, T1} =< {D2, T2}.

top([]) -> none;
top([{_Decided, _T, D, L} | _Rest]) -> {D, L}.

featured(none, _Field, _Bytes) -> none;
featured({Duel, Longest}, Field, Bytes) ->
    Rid = maps:get(id, maps:get(resident, Duel)),
    carry(Bytes, Longest, Field, [R || #{id := I} = R <- Field, I =:= Rid]).

carry(_Bytes, _Longest, _Field, []) -> none;
carry(Bytes, Longest, Field, [#{packed := RPacked, seed := Seed, arm := Arm} | _]) ->
    #{type => duel_featured,
      fact_version => ?FACT_VERSION,
      field_id => field_id(Field),
      engine_id => hex(robo_rumble:engine_id()),
      wire_version => maps:get(wire_version, robo_genome:limits()),
      %% Everything a spectator needs to regenerate every frame, and nothing else.
      challenger_id => hex(robo_genome:id(Bytes)),
      challenger_genome => base64:encode(Bytes),
      resident_id => hex(robo_genome:id(RPacked)),
      resident_genome => base64:encode(RPacked),
      resident_arm => atom_to_binary(Arm, utf8),
      resident_seed => Seed,
      %% Which of the 80 held-out geometries, and which side the challenger took.
      %% Both are needed: the two seats are different geometries, not one mirrored.
      start_split => <<"heldout">>,
      start_index => maps:get(start_index, Longest),
      challenger_seat => atom_to_binary(maps:get(seat, Longest), utf8),
      turns => maps:get(turns, Longest),
      %% Whether this duel ENDED, or ran out the turn cap. A spectator deserves to
      %% know before watching, and the selection prefers decided battles precisely
      %% because a capped one is always the longest and would otherwise always win.
      decided => maps:get(decided, Longest, false)}.

%%==============================================================================
%% visit_settled
%%==============================================================================

%% WHAT HAPPENED, flat and self-describing. The four identities that make it
%% reconstructible are `engine_id', `wire_version', `field_id' and `start_set'.
-spec visit_settled(map(), [resident_field:resident()]) -> map().
visit_settled(Row, Field) ->
    #{challenger := C, tally := T} = Row,
    #{type => visit_settled,
      fact_version => ?FACT_VERSION,
      challenger_id => hex(maps:get(id, C)),
      challenger_layers => maps:get(layers, C),
      challenger_weight_count => maps:get(weight_count, C),
      field_id => field_id(Field),
      engine_id => hex(maps:get(engine, Row)),
      wire_version => maps:get(wire_version, robo_genome:limits()),
      start_set => start_set(maps:get(start_set, T)),
      opponents => maps:get(opponents, T),
      matches => maps:get(matches, T),
      wins => maps:get(wins, T),
      losses => maps:get(losses, T),
      draws => maps:get(draws, T),
      %% Turn-cap censoring is its own number and is never folded into draws. A
      %% row whose cap share is far above the measured parity share of 0.1625 is
      %% describing a stalemate regime rather than a skill difference.
      capped => maps:get(capped, T),
      unplayable => maps:get(unplayable, T),
      results => [duel(D) || D <- maps:get(duels, Row)]}.

duel(D) ->
    #{resident_id => hex(maps:get(id, maps:get(resident, D))),
      matches => maps:get(matches, D),
      wins => maps:get(wins, D),
      losses => maps:get(losses, D),
      draws => maps:get(draws, D),
      capped => maps:get(capped, D),
      unplayable => maps:get(unplayable, D)}.

%% Flattened: the split name as a binary, never the atom, so a wire reader is not
%% required to share our atom table.
start_set(#{split := Split, count := N, digest := Digest}) ->
    #{split => atom_to_binary(Split, utf8), count => N, digest => Digest}.

%%==============================================================================
%% Helpers
%%==============================================================================

hex(Bin) when is_binary(Bin) -> binary:encode_hex(Bin).
