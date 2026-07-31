#!/usr/bin/env escript
%%! -escript main watch
%%
%% WATCH TWO TANKS FIGHT, in the terminal.
%%
%% THE REPLAY IS NOT A RECORDING. A battle is a pure function of its inputs, so
%% this ships no frames: it takes two genomes and a start index and regenerates
%% every turn locally. That is 577 bytes per tank plus one integer, against
%% however many megabytes a video of the same fight would be, and it is the whole
%% reason the engine is deterministic.
%%
%% It also means anyone can watch a PUBLISHED row. A visit_settled fact carries
%% the challenger id, the field id, the start set and the engine id, so given the
%% genomes behind those ids this reproduces exactly what the rumbler computed,
%% turn for turn, on any machine.
%%
%% Usage:
%%   scripts/watch.escript <seed-a> <seed-b> [start-index] [ms-per-frame]
%%
%%   seed-a, seed-b   resident seeds, e.g. 2001 and 2005
%%   start-index      which of the 80 held-out geometries (default 1)
%%   ms-per-frame     0 to render as fast as it computes (default 40)

-include_lib("faber_tweann/include/robo_sim.hrl").

-define(COLS, 78).
-define(ROWS, 26).

main([A, B]) -> main([A, B, "1", "40"]);
main([A, B, S]) -> main([A, B, S, "40"]);
main([A, B, S, Ms]) ->
    Field = field(),
    GA = genome(list_to_integer(A), Field),
    GB = genome(list_to_integer(B), Field),
    Start = lists:nth(list_to_integer(S), robo_starts:split(heldout)),
    io:format("~ts~n", [<<"\e[2J">>]),
    play(GA, GB, Start, list_to_integer(Ms), A, B),
    halt(0);
main(_) ->
    io:format("usage: watch.escript <seed-a> <seed-b> [start-index] [ms-per-frame]~n"
              "  e.g. watch.escript 2001 2005 1 40~n"),
    halt(1).

field() ->
    Path = "apps/hecate_robo_rumbler/priv/residents.eterm",
    {ok, F} = resident_field:load(Path),
    F.

genome(Seed, Field) ->
    case [G || #{seed := S, genome := G} <- Field, S =:= Seed] of
        [G | _] -> G;
        [] -> io:format("no resident with seed ~p~n", [Seed]), halt(1)
    end.

%% The loop is robo_rumble's, reimplemented here ONLY because that module returns
%% a result rather than yielding each turn. Nothing about the physics is
%% duplicated: every step is robo_sim's, every decision is robo_pilot's, so what
%% is drawn is what the rumbler computed and not a lookalike.
play(GA, GB, {AX, AY, AH, BX, BY, BH}, Ms, NA, NB) ->
    Arena = robo_sim:new([{a, AX, AY, AH}, {b, BX, BY, BH}]),
    loop(Arena, GA, GB, robo_pilot:init(), robo_pilot:init(), Ms, NA, NB).

loop(Arena, GA, GB, PA, PB, Ms, NA, NB) ->
    draw(Arena, NA, NB),
    pause(Ms),
    step(robo_sim:finished(Arena), Arena, GA, GB, PA, PB, Ms, NA, NB).

step(true, Arena, _GA, _GB, _PA, _PB, _Ms, NA, NB) -> verdict(Arena, NA, NB);
step(false, Arena, GA, GB, PA, PB, Ms, NA, NB) ->
    {IA, PA2} = act(a, GA, PA, Arena),
    {IB, PB2} = act(b, GB, PB, Arena),
    %% Both act on THIS arena and only then is it stepped. Reversing those two
    %% hands each tank a world one turn stale, silently: the perception contract
    %% the whole engine is built around.
    loop(robo_sim:step(Arena, [{a, IA}, {b, IB}]), GA, GB, PA2, PB2, Ms, NA, NB).

act(Id, G, P, #arena{tanks = Ts} = Arena) ->
    alive_act(lists:keyfind(Id, #tank.id, Ts), G, P, Arena).

alive_act(#tank{dead = true}, _G, P, _Arena) -> {#intent{}, P};
alive_act(#tank{} = T, G, P, Arena) -> robo_pilot:act(G, P, T, Arena).

pause(0) -> ok;
pause(Ms) -> timer:sleep(Ms).

%%==============================================================================
%% Drawing
%%==============================================================================

draw(#arena{turn = Turn, tanks = Ts, bullets = Bs}, NA, NB) ->
    Grid = plot(Bs, plot_tanks(Ts, blank())),
    io:format("~ts", [<<"\e[H">>]),
    io:format("turn ~4w   ~s~n", [Turn, bars(Ts, NA, NB)]),
    io:format("+~s+~n", [lists:duplicate(?COLS, $-)]),
    [io:format("|~ts|~n", [row(R)]) || R <- Grid],
    io:format("+~s+~n", [lists:duplicate(?COLS, $-)]).

blank() -> [[$\s || _ <- lists:seq(1, ?COLS)] || _ <- lists:seq(1, ?ROWS)].

plot_tanks(Ts, Grid) ->
    lists:foldl(fun(T, G) -> put_tank(T, G) end, Grid, Ts).

put_tank(#tank{dead = true}, Grid) -> Grid;
put_tank(#tank{id = Id, x = X, y = Y}, Grid) -> put_cell(X, Y, glyph(Id), Grid).

glyph(a) -> $A;
glyph(_B) -> $B.

plot(Bs, Grid) -> lists:foldl(fun(#bullet{x = X, y = Y}, G) ->
                                  put_cell(X, Y, $., G)
                              end, Grid, Bs).

%% Arena coordinates are FIXED POINT; the grid is characters. arena_size/0 also
%% reports fixed point, so both sides of this ratio are in the same units, which
%% is the confusion that once placed tanks 256x outside the world.
put_cell(X, Y, Ch, Grid) ->
    {W, H} = robo_sim:arena_size(),
    C = 1 + (X * (?COLS - 1)) div max(1, W),
    R = 1 + (Y * (?ROWS - 1)) div max(1, H),
    set(R, C, Ch, Grid).

set(R, C, _Ch, Grid) when R < 1; R > ?ROWS; C < 1; C > ?COLS -> Grid;
set(R, C, Ch, Grid) ->
    Row = lists:nth(R, Grid),
    New = lists:sublist(Row, C - 1) ++ [Ch] ++ lists:nthtail(C, Row),
    lists:sublist(Grid, R - 1) ++ [New] ++ lists:nthtail(R, Grid).

row(R) -> R.

bars(Ts, NA, NB) ->
    io_lib:format("A(~s) ~s   B(~s) ~s", [NA, bar(a, Ts), NB, bar(b, Ts)]).

bar(Id, Ts) -> energy_bar(lists:keyfind(Id, #tank.id, Ts)).

energy_bar(#tank{dead = true}) -> "DEAD      ";
energy_bar(#tank{energy = E}) ->
    N = max(0, min(10, E div 2560)),
    lists:duplicate(N, $#) ++ lists:duplicate(10 - N, $.).

verdict(#arena{turn = Turn} = Arena, NA, NB) ->
    io:format("~n~s~n", [outcome(robo_sim:alive(Arena), Turn, NA, NB)]).

outcome([#tank{id = a}], Turn, NA, _NB) -> io_lib:format("~s wins on turn ~p", [NA, Turn]);
outcome([#tank{id = _}], Turn, _NA, NB) -> io_lib:format("~s wins on turn ~p", [NB, Turn]);
outcome(_None_or_many, Turn, _NA, _NB) -> io_lib:format("draw after ~p turns", [Turn]).
