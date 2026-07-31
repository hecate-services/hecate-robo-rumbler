%% @doc The mesh edge: the only module here that knows a network exists.
%%
%% THIN ON PURPOSE. Everything worth testing lives in settle_visits, visit_facts
%% and visit_archive, none of which import this. So the logic is testable without
%% a realm, a pool or a network, and when the transport changes this is the only
%% file that moves.
%%
%% DEGRADES SILENTLY WHILE THE MESH IS DARK, which is the sibling services' rule
%% and is right here for a stronger reason: THE ARCHIVE IS THE POINT. A visit that
%% cannot be published has still produced a sample, and losing that sample because
%% a socket was down would be the worst possible trade. So the caller archives
%% first and publishes second, and a failed publish is reported and dropped rather
%% than retried into a queue nobody drains.
%%
%% WHAT THIS DOES NOT DO. No retry, no buffer, no delivery guarantee. A fact that
%% does not land is gone, and the archive is the durable record. Adding delivery
%% semantics without a store to back them would be a guarantee that is not one.
%%
%% RUMBLE FACTS GO OUT ON THEIR OWN REALM, and that is a boundary rather than a
%% detail. The service keeps its fleet identity for everything hecate_om does
%% (capability announcements, health), because it is a fleet service. But the
%% rumble facts are meant to be read by a public website, and handing a public web
%% container the fleet realm would let anything in that container read sentinel
%% sightings and warden facts too. Realms are how this design draws that line.
%%
%% It costs nothing to draw, because macula V2 is realm-per-call: one pool
%% publishes to any realm, so this is a second realm and not a second connection.
%% A realm id is sha256 of its name, so a public realm needs no provisioning, and
%% its name being public is the point rather than a leak.
-module(rumble_mesh).

-export([publish/2, subscribe/2, available/0, publish_realm/1]).

%%==============================================================================
%% Publishing
%%==============================================================================

%% Publish a fact on a topic. Returns what happened rather than ok, because the
%% caller logs it and a silent failure in the one module that touches the network
%% is exactly what makes a dark mesh hard to diagnose.
-spec publish(binary(), map()) -> ok | {error, term()}.
publish(Topic, Fact) when is_map(Fact) ->
    send(Topic, Fact, endpoint()).

send(_Topic, _Fact, {error, _} = E) -> E;
send(Topic, Fact, {ok, Pool, FleetRealm}) ->
    send_on(Topic, Fact, Pool, publish_realm(FleetRealm)).

send_on(_Topic, _Fact, _Pool, {error, _} = E) -> E;
send_on(Topic, Fact, Pool, {ok, Realm}) ->
    %% Wrapped, because an unreachable mesh must never take the caller down with
    %% it. This is the one place a transport error is allowed to be swallowed,
    %% and it is swallowed into a return value rather than into nothing.
    try macula:publish(Pool, Realm, Topic, Fact)
    catch Class:Reason -> {error, {publish_failed, Class, Reason}}
    end.

%%==============================================================================
%% Subscribing
%%==============================================================================

%% Subscribe to a topic. The subscriber receives whatever macula delivers; the
%% caller decides what a message means, because message shape is a transport
%% concern and this module is where transport concerns stop.
-spec subscribe(binary(), pid()) -> ok | {error, term()}.
subscribe(Topic, Subscriber) when is_pid(Subscriber) ->
    listen(Topic, Subscriber, endpoint()).

listen(_Topic, _Sub, {error, _} = E) -> E;
listen(Topic, Sub, {ok, Pool, Realm}) ->
    try macula:subscribe(Pool, Realm, Topic, Sub)
    catch Class:Reason -> {error, {subscribe_failed, Class, Reason}}
    end.

%%==============================================================================
%% The endpoint
%%==============================================================================

-spec available() -> boolean().
available() -> element(1, endpoint()) =:= ok.

%% WHERE RUMBLE FACTS GO. `HECATE_RUMBLE_REALM' is a 64-hex realm tag; unset means
%% the fleet realm, so a deployment that has not been told about the public realm
%% keeps working exactly as it did rather than silently publishing nowhere.
%%
%% A malformed tag is an ERROR, not a fallback. Falling back to the fleet realm on
%% a typo would publish public facts onto the operational realm and look fine.
%% The fallback is PASSED IN, already resolved, rather than looked up again here.
%% The first version called realm/0 a second time, which returns `unavailable'
%% rather than an error tuple, so an unset variable reached send_on/4 in a shape
%% it had no clause for. Taking the realm the caller already holds removes both
%% the second lookup and the mismatch.
-spec publish_realm(binary()) -> {ok, binary()} | {error, term()}.
publish_realm(Fallback) -> parse_realm(os:getenv("HECATE_RUMBLE_REALM"), Fallback).

parse_realm(S, _Fallback) when is_list(S), S =/= "" ->
    decoded(catch binary:decode_hex(unicode:characters_to_binary(S)));
parse_realm(_Unset, Fallback) ->
    {ok, Fallback}.

decoded(<<R:32/binary>>) -> {ok, R};
decoded(_Bad) -> {error, rumble_realm_not_64_hex}.

%% The pool and realm hecate_om wired at boot. Both absent is the ordinary state
%% before boot and while the mesh is down, so it is a value rather than a crash.
endpoint() -> pair(client(), realm()).

pair({ok, Pool}, {ok, Realm}) -> {ok, Pool, Realm};
pair({ok, _Pool}, _NoRealm) -> {error, no_realm};
pair(_NoClient, _Realm) -> {error, no_macula_client}.

client() -> guarded(fun hecate_om:macula_client/0).

realm() -> guarded(fun hecate_om_identity:realm/0).

%% hecate_om raises when it has not booted, which is a normal state for a service
%% starting up or running without a mesh, not an exception worth propagating.
guarded(F) ->
    try wrap(F())
    catch _Class:_Reason -> unavailable
    end.

%% AN ERROR TUPLE IS NOT A VALUE, AND THE FIRST VERSION TREATED IT AS ONE. The
%% catch-all clause below used to accept anything, so hecate_om_identity:realm()
%% returning {error, no_realm} became {ok, {error, no_realm}}: available/0
%% reported TRUE with no realm, and that error tuple was handed to macula as the
%% realm, which raised function_clause inside the subscribe. Booted against the
%% live mesh this printed "mesh up: true" while the service could neither
%% subscribe nor publish. A health signal that lies is worse than no health
%% signal, and only a real boot exposed it.
wrap(undefined) -> unavailable;
wrap({error, _Why}) -> unavailable;
wrap({ok, V}) -> {ok, V};
wrap(V) -> {ok, V}.
