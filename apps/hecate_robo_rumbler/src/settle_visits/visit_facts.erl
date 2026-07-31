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

-export([field_published/1, visit_settled/2, field_id/1, topic/1]).

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
-spec topic(field | visit) -> binary().
topic(What) -> <<(namespace())/binary, "/", (leaf(What))/binary>>.

leaf(field) -> <<"field">>;
leaf(visit) -> <<"visit">>.

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
