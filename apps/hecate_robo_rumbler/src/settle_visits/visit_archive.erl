%% @doc The archive: every genome that ever visited, and the journal of what happened.
%%
%% THIS EXISTS BECAUSE THE GENOMES ARE THE POINT. The rows are a scoreboard; the
%% genomes are the science. Robo Rumble phase 1 stalled because 20 champions from
%% one optimiser at one budget are very nearly totally ordered, and the question
%% needs many INDEPENDENTLY TRAINED populations from people who never coordinated.
%% This service is how those arrive. A row published against a content id whose
%% preimage nobody kept is a receipt for a sample we threw away: no
%% visitor-against-visitor cross-play later, nothing to build a future field from,
%% nothing to hand a detector.
%%
%% At 577 bytes a tank, ten thousand distinct visitors is under six megabytes.
%% Storage was never the reason to defer this.
%%
%% CONTENT-ADDRESSED, WHICH BUYS THREE THINGS AT ONCE. Dedup is exact, so the same
%% tank arriving a thousand times is one entry and a flood costs nothing while
%% still adding samples. Two hosts name the same genome identically without
%% coordinating. And the name is checkable, which is what self_check below is for.
%%
%% APPEND-ONLY, AND A DUPLICATE IS VERIFIED RATHER THAN OVERWRITTEN. Writing over
%% an existing entry with "the same" bytes is safe only if they really are the
%% same, and if they are not then the overwrite destroys the evidence that
%% something is badly wrong. So a repeat arrival READS what is there and compares.
%%
%% ONE JOURNAL, TWO KINDS OF ENTRY, and that is deliberate. Field publications and
%% visits go into the same append-only log, so a row is attributable to whichever
%% field entry precedes it by FILE ORDER alone. No sequence number to get wrong,
%% no clock to disagree about. When a later version lets the resident field
%% evolve, every row before and after a change is unambiguously attributable to
%% the exact field it faced.
%%
%% SINGLE WRITER. Ordering is append order, which is correct for one process and
%% is stated rather than assumed. A second concurrent writer would interleave
%% safely at the OS level but the two would race on the read-modify-write in
%% put_genome/2's duplicate check. There is one writer today; when there are two,
%% this needs a serialising owner and this comment is the warning.
-module(visit_archive).

-export([put_genome/2, get_genome/2, has_genome/2, genome_count/1]).
-export([append/2, journal/1, journal_count/1]).
-export([self_check/1]).

-define(GENOME_EXT, ".rg").
-define(JOURNAL, "journal.eterm").

%%==============================================================================
%% Genomes
%%==============================================================================

%% Store a packed genome under its own content id. Returns the id either way, so
%% a caller does not care whether this visitor is new.
%%
%% THE ID IS COMPUTED FROM THE BYTES BEING WRITTEN, never passed in. An id
%% supplied by a caller could name something other than what is stored, and the
%% archive would then hand back bytes that are not what the id says they are,
%% which is the worst thing an archive can do.
-spec put_genome(file:filename_all(), binary()) -> {ok, binary()} | {error, term()}.
put_genome(Dir, Bytes) when is_binary(Bytes) ->
    Id = robo_genome:id(Bytes),
    store(Dir, Id, Bytes, path(Dir, Id));
put_genome(_Dir, _NotBytes) -> {error, not_a_binary}.

store(_Dir, Id, Bytes, Path) ->
    ok = filelib:ensure_dir(Path),
    existing(Id, Bytes, Path, file:read_file(Path)).

%% Already here: verify rather than overwrite. Identical bytes are the normal
%% case and cost one read. DIFFERENT bytes under one id mean either a sha256
%% collision or a defect in how the id is computed, and either way the stored
%% copy must survive so the disagreement can be examined.
existing(Id, Bytes, _Path, {ok, Bytes}) -> {ok, Id};
existing(Id, _Bytes, Path, {ok, Other}) ->
    {error, {id_collision, Id, Path, byte_size(Other)}};
existing(Id, Bytes, Path, {error, enoent}) -> write_new(Id, Bytes, Path);
existing(_Id, _Bytes, Path, {error, Why}) -> {error, {unreadable, Path, Why}}.

%% Written to a temporary name and renamed, because rename is atomic on POSIX
%% while a partial write is not. A crash mid-write would otherwise leave a
%% truncated file whose name still claims to be a whole genome.
write_new(Id, Bytes, Path) ->
    Tmp = Path ++ ".part",
    renamed(Id, Path, Tmp, file:write_file(Tmp, Bytes)).

renamed(Id, Path, Tmp, ok) -> moved(Id, file:rename(Tmp, Path));
renamed(_Id, _Path, Tmp, {error, Why}) -> {error, {unwritable, Tmp, Why}}.

moved(Id, ok) -> {ok, Id};
moved(_Id, {error, Why}) -> {error, {rename_failed, Why}}.

%% VERIFIES ON EVERY READ. The id is a hash of the content, so the archive can
%% always check that what it hands back is what the name promises. That catches
%% disk corruption, a truncated write that somehow survived, and a file edited by
%% hand, none of which would otherwise announce themselves.
-spec get_genome(file:filename_all(), binary()) -> {ok, binary()} | {error, term()}.
get_genome(Dir, Id) -> verify(Id, file:read_file(path(Dir, Id))).

verify(Id, {ok, Bytes}) -> checked(Id, Bytes, robo_genome:id(Bytes));
verify(_Id, {error, enoent}) -> {error, not_found};
verify(_Id, {error, Why}) -> {error, Why}.

checked(Id, Bytes, Id) -> {ok, Bytes};
checked(Id, _Bytes, Actual) -> {error, {corrupt, Id, Actual}}.

-spec has_genome(file:filename_all(), binary()) -> boolean().
has_genome(Dir, Id) -> filelib:is_regular(path(Dir, Id)).

-spec genome_count(file:filename_all()) -> non_neg_integer().
genome_count(Dir) ->
    length(filelib:wildcard(filename:join([Dir, "genomes", "*", "*" ?GENOME_EXT]))).

%% Sharded on the first byte of the id, so one directory does not accumulate
%% every genome ever seen.
path(Dir, Id) ->
    Hex = binary_to_list(binary:encode_hex(Id)),
    filename:join([Dir, "genomes", string:slice(Hex, 0, 2), Hex ++ ?GENOME_EXT]).

%%==============================================================================
%% The journal
%%==============================================================================

%% Append one entry. Field publications and visits share the log so that file
%% order alone attributes a row to the field it actually faced.
%%
%% Entries are written as Erlang terms, one per line, which appends cleanly and
%% reads back with file:consult/1. A term is used rather than a hand-rolled
%% encoding because this file is LOCAL and is not a wire format: nothing outside
%% this host reads it, so the cross-release byte-stability problem that forced
%% robo_genome to hand-roll its packing does not apply here.
-spec append(file:filename_all(), {field | visit, term()}) -> ok | {error, term()}.
append(Dir, {Kind, _Payload} = Entry) when Kind =:= field; Kind =:= visit ->
    Path = filename:join(Dir, ?JOURNAL),
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, io_lib:format("~p.~n", [Entry]), [append]);
append(_Dir, _Bad) -> {error, unknown_entry_kind}.

-spec journal(file:filename_all()) -> {ok, [term()]} | {error, term()}.
journal(Dir) -> read_journal(file:consult(filename:join(Dir, ?JOURNAL))).

read_journal({ok, Entries}) -> {ok, Entries};
read_journal({error, enoent}) -> {ok, []};
read_journal({error, Why}) -> {error, Why}.

-spec journal_count(file:filename_all()) -> non_neg_integer().
journal_count(Dir) -> counted(journal(Dir)).

counted({ok, Entries}) -> length(Entries);
counted({error, _}) -> 0.

%%==============================================================================
%% Checking the whole thing
%%==============================================================================

%% Re-hash every stored genome and report the ones whose content no longer
%% matches their name. Cheap enough to run on boot for a small archive, and it is
%% the only way silent corruption ever surfaces: nothing else reads these files
%% until someone asks for a specific one, which may be never.
-spec self_check(file:filename_all()) -> {ok, non_neg_integer()} | {corrupt, [binary()]}.
self_check(Dir) ->
    Files = filelib:wildcard(filename:join([Dir, "genomes", "*", "*" ?GENOME_EXT])),
    Bad = [F || F <- Files, not intact(F)],
    verdict(length(Files), Bad).

verdict(N, []) -> {ok, N};
verdict(_N, Bad) -> {corrupt, [list_to_binary(filename:basename(F)) || F <- Bad]}.

intact(File) -> matches(File, file:read_file(File)).

matches(File, {ok, Bytes}) ->
    Named = filename:rootname(filename:basename(File)),
    binary_to_list(binary:encode_hex(robo_genome:id(Bytes))) =:= Named;
matches(_File, {error, _}) -> false.
