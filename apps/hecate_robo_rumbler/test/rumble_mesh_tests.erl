%% @doc Tests for the mesh edge, WITHOUT a mesh.
%%
%% THE PROPERTY THAT MATTERS IS THAT A DARK MESH COSTS NOTHING. This service
%% exists to collect samples, so a socket being down must never take a visit with
%% it. These run with no realm, no pool and no network, which is exactly the
%% condition the code has to survive.
%% @end
-module(rumble_mesh_tests).

-include_lib("eunit/include/eunit.hrl").

%% With hecate_om unbooted there is no client and no realm. Every entry point
%% must return a value rather than raise, because a raise here would propagate
%% into the visit path and lose the sample the visit was for.
dark_mesh_reports_unavailable_test() ->
    ?assertNot(rumble_mesh:available()).

publish_on_a_dark_mesh_is_an_error_not_a_crash_test() ->
    ?assertMatch({error, _}, rumble_mesh:publish(<<"t/x">>, #{type => probe})).

subscribe_on_a_dark_mesh_is_an_error_not_a_crash_test() ->
    ?assertMatch({error, _}, rumble_mesh:subscribe(<<"t/x">>, self())).

%% The reason is named rather than swallowed, so a dark mesh is diagnosable
%% instead of merely quiet.
the_reason_is_specific_test() ->
    ?assertEqual({error, no_macula_client}, rumble_mesh:publish(<<"t/x">>, #{})).
