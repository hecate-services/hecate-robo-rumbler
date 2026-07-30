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

## Status

**v1, and honest about it.** No ranking, no ledger, no verifier, no commit-reveal,
a scratch topic. Storeless: the plan's own tier table says an embedded store earns
its place at ranked visits, and there is no ranking here yet.

Owed next, in order: archive every visiting genome from the first visit (a row
keyed by a content id whose preimage nobody kept is a receipt for a sample thrown
away), define the published fact as an explicit flat schema rather than an internal
map, and name a per-battle compute budget before a legal maximum-size genome finds
the gap.

## Build

    rebar3 compile
    rebar3 eunit
    rebar3 as lint lint

The engine is `faber_tweann`, used as a **library**. Its application is
deliberately not started: the `robo_*` modules are pure, while that application
brings up a supervisor and a morphology registry a rumbler has no use for.

## Licence

Apache-2.0.
