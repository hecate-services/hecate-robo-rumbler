#!/usr/bin/env escript
%%! -escript main render
%%
%% RENDER A DUEL TO A SELF-CONTAINED HTML PAGE.
%%
%% THE PHYSICS IS NOT REIMPLEMENTED IN JAVASCRIPT, DELIBERATELY. A second
%% implementation of the engine would be the copy-against-a-copy hazard this
%% front has already been bitten by, and worse, it would break the one property
%% everything here rests on: that a battle replays bit-identically anywhere. So
%% the Erlang engine computes every frame and the page only plays them back.
%%
%% THAT MAKES THIS A RECORDING, AND A RECORDING IS CHECKABLE. The page carries the
%% two genome content ids, the start index and the engine id, so anyone can re-run
%% the battle from those inputs and confirm the frames. A recording you cannot
%% verify is a claim; one you can is evidence.
%%
%% Usage:
%%   scripts/render.escript <seed-a> <seed-b> [start-index] [out.html]

-include_lib("faber_tweann/include/robo_sim.hrl").

main([A, B]) -> main([A, B, "1", "duel.html"]);
main([A, B, S]) -> main([A, B, S, "duel.html"]);
main([A, B, S, Out]) ->
    Field = field(),
    SA = list_to_integer(A), SB = list_to_integer(B),
    GA = genome(SA, Field), GB = genome(SB, Field),
    Idx = list_to_integer(S),
    Start = lists:nth(Idx, robo_starts:split(heldout)),
    Frames = record(GA, GB, Start),
    Html = page(#{a => SA, b => SB, start => Idx,
                  id_a => hex(robo_genome:id(GA)), id_b => hex(robo_genome:id(GB)),
                  engine => hex(robo_rumble:engine_id()),
                  frames => Frames}),
    ok = file:write_file(Out, Html),
    io:format("~s: ~p frames, ~p bytes~n", [Out, length(Frames), byte_size(Html)]),
    halt(0);
main(_) ->
    io:format("usage: render.escript <seed-a> <seed-b> [start-index] [out.html]~n"),
    halt(1).

field() ->
    {ok, F} = resident_field:load("apps/hecate_robo_rumbler/priv/residents.eterm"),
    F.

genome(Seed, Field) ->
    case [G || #{seed := S, genome := G} <- Field, S =:= Seed] of
        [G | _] -> G;
        [] -> io:format("no resident with seed ~p~n", [Seed]), halt(1)
    end.

%%==============================================================================
%% Recording. Every step is robo_sim's and every decision robo_pilot's, so what
%% is drawn is what the rumbler counts, not a lookalike.
%%==============================================================================

record(GA, GB, {AX, AY, AH, BX, BY, BH}) ->
    Arena = robo_sim:new([{a, AX, AY, AH}, {b, BX, BY, BH}]),
    walk(Arena, GA, GB, robo_pilot:init(), robo_pilot:init(), []).

walk(Arena, GA, GB, PA, PB, Acc) ->
    Acc2 = [frame(Arena) | Acc],
    next(robo_sim:finished(Arena), Arena, GA, GB, PA, PB, Acc2).

next(true, _Arena, _GA, _GB, _PA, _PB, Acc) -> lists:reverse(Acc);
next(false, Arena, GA, GB, PA, PB, Acc) ->
    {IA, PA2} = act(a, GA, PA, Arena),
    {IB, PB2} = act(b, GB, PB, Arena),
    %% Both act on THIS arena and only then is it stepped: the perception
    %% contract, carried over rather than re-derived.
    walk(robo_sim:step(Arena, [{a, IA}, {b, IB}]), GA, GB, PA2, PB2, Acc).

act(Id, G, P, #arena{tanks = Ts} = Arena) ->
    live(lists:keyfind(Id, #tank.id, Ts), G, P, Arena).

live(#tank{dead = true}, _G, P, _Arena) -> {#intent{}, P};
live(#tank{} = T, G, P, Arena) -> robo_pilot:act(G, P, T, Arena).

%% Whole units, not fixed point, so the page never has to know the engine's
%% scale. Compact arrays rather than objects: a 500-turn duel is then tens of
%% kilobytes rather than hundreds.
frame(#arena{tanks = Ts, bullets = Bs}) ->
    [[tank(T) || T <- Ts], [[u(X), u(Y)] || #bullet{x = X, y = Y} <- Bs]].

tank(#tank{x = X, y = Y, heading = H, gun = G, energy = E, dead = D}) ->
    [u(X), u(Y), H, G, max(0, E div 256), bit(D)].

u(V) -> V div 256.
bit(true) -> 1;
bit(false) -> 0.

hex(Bin) -> binary_to_list(binary:encode_hex(Bin)).

%%==============================================================================
%% The page
%%==============================================================================

page(#{a := A, b := B, start := Idx, id_a := IdA, id_b := IdB,
       engine := Eng, frames := Frames}) ->
    {W, H} = robo_sim:arena_size(),
    Json = frames_json(Frames),
    Last = lists:last(Frames),
    unicode:characters_to_binary(io_lib:format(template(),
        %% ORDER FOLLOWS THE TEMPLATE, and the provenance block sits BEFORE the
        %% script, so the frame data comes LAST. The first version put it in the
        %% middle, which shifts every later argument by one: io_lib:format would
        %% have rendered a page with the genome ids and the engine id in each
        %% other's places, and it would still have looked like a page.
        [A, B, A, B, Idx, length(Frames) - 1, verdict(Last, A, B),
         W div 256, H div 256,
         A, string:slice(IdA, 0, 16), B, string:slice(IdB, 0, 16),
         Idx, string:slice(Eng, 0, 16),
         Json])).

verdict([Ts, _Bs], A, B) -> settle([D || [_, _, _, _, _, D] <- Ts], A, B).

settle([0, 1], A, _B) -> integer_to_list(A) ++ " wins";
settle([1, 0], _A, B) -> integer_to_list(B) ++ " wins";
settle(_Both, _A, _B) -> "draw".

frames_json(Frames) -> ["[", lists:join(",", [f(F) || F <- Frames]), "]"].

f([Ts, Bs]) -> ["[[", lists:join(",", [arr(T) || T <- Ts]), "],[",
                lists:join(",", [arr(P) || P <- Bs]), "]]"].

arr(L) -> ["[", lists:join(",", [integer_to_list(V) || V <- L]), "]"].

template() ->
"<!doctype html><html><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>Robo Rumble: ~w vs ~w</title>
<style>
 :root{--bg:#faf9f7;--fg:#1a1a1a;--dim:#6b6b6b;--line:#d8d5d0;--a:#C7583F;--b:#2b6cb0;--amber:#F2B142}
 @media (prefers-color-scheme:dark){:root{--bg:#14161a;--fg:#e8e6e3;--dim:#9a9691;--line:#2c3038}}
 :root[data-theme=dark]{--bg:#14161a;--fg:#e8e6e3;--dim:#9a9691;--line:#2c3038}
 :root[data-theme=light]{--bg:#faf9f7;--fg:#1a1a1a;--dim:#6b6b6b;--line:#d8d5d0}
 *{box-sizing:border-box}
 body{margin:0;padding:1.5rem;background:var(--bg);color:var(--fg);
   font:15px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
 .wrap{max-width:900px;margin:0 auto}
 h1{font-size:1.1rem;font-weight:600;margin:0 0 .25rem}
 .sub{color:var(--dim);font-size:.85rem;margin-bottom:1rem}
 canvas{width:100%;height:auto;display:block;border:1px solid var(--line);
   border-radius:6px;background:var(--bg)}
 .hud{display:flex;gap:1.5rem;flex-wrap:wrap;align-items:center;margin:.75rem 0}
 .bar{flex:1;min-width:180px}
 .bar .lab{font-size:.8rem;margin-bottom:.2rem}
 .bar .track{height:8px;background:var(--line);border-radius:4px;overflow:hidden}
 .bar .fill{height:100%;transition:width .05s linear}
 .ctl{display:flex;gap:.75rem;align-items:center;margin:.75rem 0}
 button{font:inherit;padding:.35rem .9rem;border:1px solid var(--line);
   border-radius:5px;background:transparent;color:var(--fg);cursor:pointer}
 button:hover{border-color:var(--amber)}
 input[type=range]{flex:1;accent-color:var(--amber)}
 .prov{color:var(--dim);font-size:.75rem;border-top:1px solid var(--line);
   padding-top:.75rem;margin-top:1rem}
 .prov code{color:var(--fg)}
</style></head><body><div class=\"wrap\">
<h1>~w vs ~w</h1>
<div class=\"sub\">start ~w of 80 &middot; ~w turns &middot; ~s</div>
<canvas id=\"c\" width=\"~w\" height=\"~w\"></canvas>
<div class=\"hud\">
 <div class=\"bar\"><div class=\"lab\" id=\"la\"></div>
   <div class=\"track\"><div class=\"fill\" id=\"fa\" style=\"background:var(--a)\"></div></div></div>
 <div class=\"bar\"><div class=\"lab\" id=\"lb\"></div>
   <div class=\"track\"><div class=\"fill\" id=\"fb\" style=\"background:var(--b)\"></div></div></div>
</div>
<div class=\"ctl\">
 <button id=\"play\">pause</button>
 <input type=\"range\" id=\"scrub\" min=\"0\" value=\"0\">
 <span id=\"turn\"></span>
</div>
<div class=\"prov\">
 <p><strong>This is a recording, and it is checkable.</strong> The frames were
 computed by the Erlang engine, not by this page: reimplementing the physics in
 JavaScript would be a second implementation to drift, and would break the one
 property the whole thing rests on, that a battle replays bit-identically
 anywhere. Given the two genomes and the start index below, anyone can regenerate
 these frames and confirm them.</p>
 <p>tank A <code>~w</code> &middot; genome <code>~s...</code><br>
    tank B <code>~w</code> &middot; genome <code>~s...</code><br>
    start <code>~w</code> of the 80 held-out geometries &middot;
    engine <code>~s...</code></p>
</div>
</div>
<script>
const F=~s;
const c=document.getElementById('c'),x=c.getContext('2d');
const W=c.width,H=c.height;
const cs=getComputedStyle(document.documentElement);
const col=n=>cs.getPropertyValue(n).trim();
let i=0,playing=true;
const scrub=document.getElementById('scrub');scrub.max=F.length-1;
function draw(){
 const [ts,bs]=F[i];
 x.clearRect(0,0,W,H);
 x.strokeStyle=col('--line');x.lineWidth=2;x.strokeRect(1,1,W-2,H-2);
 x.fillStyle=col('--fg');
 for(const [bx,by] of bs){x.beginPath();x.arc(bx,by,3,0,7);x.fill();}
 ts.forEach((t,n)=>{
  const [tx,ty,h,g,e,dead]=t;
  const c1=n===0?col('--a'):col('--b');
  if(dead){x.strokeStyle=c1;x.lineWidth=2;
   x.beginPath();x.moveTo(tx-9,ty-9);x.lineTo(tx+9,ty+9);
   x.moveTo(tx+9,ty-9);x.lineTo(tx-9,ty+9);x.stroke();return;}
  x.save();x.translate(tx,ty);
  x.rotate(h*Math.PI/128);
  x.fillStyle=c1;x.fillRect(-11,-8,22,16);
  x.restore();
  x.save();x.translate(tx,ty);x.rotate(g*Math.PI/128);
  x.strokeStyle=col('--amber');x.lineWidth=3;
  x.beginPath();x.moveTo(0,0);x.lineTo(20,0);x.stroke();x.restore();
 });
 const [ta,tb]=ts;
 document.getElementById('fa').style.width=Math.max(0,Math.min(100,ta[4]/100))+'%';
 document.getElementById('fb').style.width=Math.max(0,Math.min(100,tb[4]/100))+'%';
 document.getElementById('la').textContent='A  '+(ta[5]?'destroyed':ta[4]);
 document.getElementById('lb').textContent='B  '+(tb[5]?'destroyed':tb[4]);
 document.getElementById('turn').textContent='turn '+i+' / '+(F.length-1);
 scrub.value=i;
}
function tick(){if(playing){i=(i+1)%F.length;draw();}setTimeout(tick,40);}
document.getElementById('play').onclick=e=>{playing=!playing;
 e.target.textContent=playing?'pause':'play';};
scrub.oninput=e=>{i=+e.target.value;playing=false;
 document.getElementById('play').textContent='play';draw();};
draw();tick();
</script></body></html>".
