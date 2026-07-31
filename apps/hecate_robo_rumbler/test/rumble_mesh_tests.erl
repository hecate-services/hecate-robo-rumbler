%% @doc Tests for the mesh edge, which is almost all about WHERE facts go.
%%
%% The transport itself is deliberately untested here: it needs a realm, a pool
%% and a network, and everything worth asserting lives in settle_visits,
%% visit_facts and visit_archive, none of which import this module. What IS worth
%% asserting is the realm choice, because a wrong one publishes real facts onto
%% the wrong realm and looks entirely successful.
%% @end
-module(rumble_mesh_tests).

-include_lib("eunit/include/eunit.hrl").

%% Unset means the fleet realm, so a deployment that has never heard of the public
%% realm keeps behaving exactly as it did.
unset_falls_back_to_the_fleet_realm_test() ->
    Fleet = crypto:hash(sha256, <<"the.fleet.realm">>),
    with_env(false, fun() ->
        ?assertEqual({ok, Fleet}, rumble_mesh:publish_realm(Fleet))
    end).

a_64_hex_tag_is_the_publish_realm_test() ->
    Hex = "0a346d25957755075dabefcc88e03c050df86ce3b7dc5a5a63ff38f32462c352",
    with_env(Hex, fun() ->
        {ok, Realm} = rumble_mesh:publish_realm(fleet()),
        ?assertEqual(32, byte_size(Realm)),
        ?assertEqual(binary:decode_hex(list_to_binary(Hex)), Realm)
    end).

%% THE REALM IS SHA-256 OF ITS NAME, which is why a public realm needs no
%% provisioning and why its name can be stated openly. Freezing the pairing here
%% means a rename cannot silently keep the old tag.
the_public_realm_is_the_hash_of_its_name_test() ->
    ?assertEqual(binary:decode_hex(<<"0a346d25957755075dabefcc88e03c050df86ce3b7dc5a5a63ff38f32462c352">>),
                 crypto:hash(sha256, <<"net.beamcampus.rumble">>)).

%% A TYPO MUST NOT FALL BACK. Falling back to the fleet realm on a malformed tag
%% would publish public facts onto the operational realm and report success.
malformed_tag_is_an_error_not_a_fallback_test() ->
    [with_env(Bad, fun() ->
        ?assertEqual({error, rumble_realm_not_64_hex}, rumble_mesh:publish_realm(fleet()))
     end) || Bad <- ["abc", "zz346d25957755075dabefcc88e03c050df86ce3b7dc5a5a63ff38f32462c352",
                     "0a346d25957755075dabefcc88e03c050df86ce3b7dc5a5a63ff38f32462c35"]].

%%==============================================================================
%% Helpers
%%==============================================================================

fleet() -> crypto:hash(sha256, <<"the.fleet.realm">>).

with_env(false, F) ->
    Prev = os:getenv("HECATE_RUMBLE_REALM"),
    os:unsetenv("HECATE_RUMBLE_REALM"),
    try F() after restore(Prev) end;
with_env(Value, F) ->
    Prev = os:getenv("HECATE_RUMBLE_REALM"),
    os:putenv("HECATE_RUMBLE_REALM", Value),
    try F() after restore(Prev) end.

restore(false) -> os:unsetenv("HECATE_RUMBLE_REALM");
restore(Prev) -> os:putenv("HECATE_RUMBLE_REALM", Prev).
