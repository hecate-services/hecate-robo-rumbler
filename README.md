# hecate-robo-rumbler

A visiting tank fights the resident field, and the result is published.

**This exists so a tank can fight on a stranger's machine.** A leaf node accepts a
genome over the mesh, runs it against 40 trained residents, and publishes the row.
Nothing recomputes the battle and no second machine has to agree, because only one
ever runs the fight.

## Why it is not only a game

The [Robo Rumble plan](https://github.com/rgfaber/faber-ecosystem/blob/master/plans/PLAN_ROBO_RUMBLE.md)
asked whether coevolution produces intransitive, rock-paper-scissors dynamics.
That question stalled: 20 champions from one optimiser at one budget turn out to
be very nearly totally ordered, and the small cyclic residue tracks behavioural
regime rather than skill, vanishing when two outliers are dropped. The question
needs many **independently trained** populations from people who never
coordinated.

This service is how those arrive. Every visiting genome is a sample the research
cannot otherwise obtain, which is why the archive matters more than the ranking.

## What a visitor sends

A genome: a topology and a flat list of integer weights, in the canonical wire
format from `robo_genome`. A trained tank is **577 bytes**. The first layer must
be 17 wide (the sensor channels) and the last 5 (the controls); anything else is
refused rather than padded, because `robo_net` pads in silence and the row would
otherwise look real.

## What comes back

The visitor's full row: the outcome against every resident by content id, over the
**80 held-out starts** of `robo_starts`, both seats. That is 6,400 matches and
about 13 seconds.

Those 80 are the same geometries phase 0 measured its endpoint on, so a row here is
directly comparable with the archived cross-play matrix.

Raw counts, and no rating. A rating implies a scalar skill, and whether one exists
here is precisely the open question.

## The resident field is not a neutral sample

Forty champions from the phase 0 archive: 20 from one optimiser on one topology,
10 with no hidden layer, and 10 trained against a single opponent rather than the
full ladder. Real and diverse, and not a random draw from the space of tanks. That
caveat travels on the wire with every result, because a qualifier that lives only
in a README is a qualifier nobody sees.

## It works

First correct rumble, 2026-07-31. Visitor on a laptop, rumbler in a container on
**beam03**, meeting only through the deployed mesh:

    laptop -> station-de-frankfurt -> ... mesh ... -> station-fi-helsinki -> beam03

    === ROW ===
    opponents : 40
    matches   : 6400
    won       : 2250
    lost      : 4126
    drawn     : 24
    turn-cap  : 5

**An earlier row published from a laptop-only run is withdrawn.** It reported 2400
won, 3840 lost, 160 drawn and zero turn-caps, and it was measured on the wrong
geometry: that build's engine dependency was stale and silently ignored the
placement option, so every duel ran on the circle rather than the 80 measured
starts. The tell was in the numbers and was read backwards at the time. Zero
turn-caps across 6,400 matches is not a clean sheet, it is the signature of one
head-on start replayed 6,400 times.

**Determinism across machines is confirmed, empirically.** The same fully
specified battle produces a byte-identical trace hash and turn count on OTP 28
here and OTP 27 in the container: `F08A7A749BB584287B5673EEF9BED81E…`, 134 turns.
That is the property `exp068` was written to measure, answered in the field.

Send one yourself:

    scripts/visit.escript <genome-file>

## Watch a duel

    scripts/watch.escript  2001 2005 1 40      # in the terminal
    scripts/render.escript 2001 2005 1 duel.html   # a shareable page

A whole battle is **19 KB**: 234 frames of two tanks, bullets, headings and
energy. The physics is **not** reimplemented in JavaScript, deliberately, because
a second implementation would drift and would break the property everything here
rests on. The Erlang engine computes every frame; the page only plays them back.

That makes it a recording, and a recording that carries both genome ids, the start
index and the engine id is **checkable**: anyone can regenerate the frames from
those inputs and confirm them. A recording you cannot verify is a claim.

**This is a first step, not the destination.** Watching one battle is not what
made Robocode worth showing up for. That was the metagame between authors:
publish a champion, study it, counter it, get countered. None of that loop exists
yet, and no amount of rendering substitutes for it. What is missing is a way to
make a tank, opponents returned with your row so you have something to train
against, and a ladder that remembers.

## Status

**v1, and honest about it.** No ranking, no ledger, no verifier, no commit-reveal,
a scratch topic. Storeless: the plan's own tier table says an embedded store earns
its place at ranked visits, and there is no ranking here yet.

Done since: the archive (content-addressed, append-only, self-verifying on read),
the published facts as an explicit flat schema, and a per-visit compute budget.

### Concurrency

The server owns the field and every write and does no arithmetic, so a health
check answers during a battle. Battles run in spawned workers, which are pure and
therefore safe to run several at a time, bounded by the scheduler count. Excess
visits QUEUE rather than being refused, because a visitor who waits still gets a
row and a visitor who is refused is a sample lost.

A second gen_server would have fixed the health check and given no concurrency:
one message at a time means the second visitor still queues behind the first.

The mesh is wired: `hecate_om:boot/2` supplies the pool and realm, the manifest is
published once at boot, and a genome arriving on the topic settles a visit.

**The order of operations is the design, and it is not the obvious one.** Archive
the genome first, before it is even judged, because a visiting genome is a sample
the research cannot otherwise obtain and everything after that step can fail
without losing it. Then settle, then journal locally, then publish outward
best-effort. A dark mesh costs a fact, never a sample. Even a REFUSED genome is
kept, because a refusal is information about what people send and the bytes cost
577.

Owed next: migration. Today a visitor gets a row back and nothing else. What would
close the loop is opponents: come home with genomes to train against, improve,
return. That is phase 2 islands in the plan, and it is only possible because the
archive keeps what arrives.

### Four facts

`field_published` carries the manifest, once per field version: every resident id,
arm and seed, plus a `field_id` derived by hashing the sorted resident ids.

`visit_started` is emitted the moment a genome is archived, BEFORE it is judged.
A row lands about thirteen seconds later and liveness cannot wait for it: a
spectator has to be able to say "someone is fighting right now" while it is true.

`visit_settled` carries the row and four identities that make it reconstructible
later: which engine, which wire format, which field, which start set. Rows carry
only the `field_id` and a reader joins, so a row never hauls forty manifests.

`duel_featured` carries **one battle worth watching**, and it carries genomes
rather than frames. A visit is 6,400 battles of roughly 200 turns, about 1.28
million frames and 93 MB. The two genomes and a start index are about 1.2 KB and
say exactly the same thing, because the engine is deterministic: any spectator
holding that fact regenerates every frame locally and gets the same battle, turn
for turn. The battle chosen is the longest across the row, longest being a proxy
for closest fought. A test asserts the regenerated battle matches the turn count
the rumbler counted, because a fact that cannot be replayed is decoration.

No tuples on the wire, atom keys only, ids as hex. Each of those is a rule earned
by something that broke elsewhere.

**`duel_featured` republishes a visitor's genome.** That is a deliberate
disclosure, not an accident: send a tank here and its bytes may be broadcast to
anyone watching. Said plainly because a visitor cannot infer it from "submit a
genome, get a row back".

### Rumble facts have their own realm

The service keeps its fleet identity for everything `hecate_om` does, because it
is a fleet service. But the rumble facts are meant to be read by a **public
website**, and handing a public web container the fleet realm tag would let
anything in that container read sentinel sightings and warden facts too. Realms
are how this design draws that line, so the facts go out on their own:

    net.beamcampus.rumble
    0a346d25957755075dabefcc88e03c050df86ce3b7dc5a5a63ff38f32462c352

Set `HECATE_RUMBLE_REALM` to that tag. Unset falls back to the fleet realm, so a
deployment that has not been told about the public realm keeps behaving as it
did. A **malformed** tag is an error rather than a fallback: falling back on a
typo would publish public facts onto the operational realm and report success.

It costs nothing to draw this line. macula V2 is realm-per-call, so one pool
publishes to any realm and this is a second realm, not a second connection. A
realm id is `sha256` of its name, so a public realm needs no provisioning, and
its name being public is the point rather than a leak.

Worth stating plainly: stations are realm-agnostic infrastructure, so a realm is
a routing namespace and not an enforced permission. What this buys is that a
public web box never holds the fleet tag, not that the fleet tag would be
refused if it did.

### Two different limits

The wire format caps what a genome may *be*. The service separately caps what one
visit may *cost*, because the format cannot know the field size or the start set.
A 2,305-weight genome is comfortably legal and would spend 14.7 million weight
evaluations on a full row, so it is refused with the arithmetic in the reason.

## Build

    rebar3 compile
    rebar3 eunit
    rebar3 as lint lint

The engine is `faber_tweann`, used as a **library**. Its application is
deliberately not started: the `robo_*` modules are pure, while that application
brings up a supervisor and a morphology registry a rumbler has no use for.

## Licence

Apache-2.0.
