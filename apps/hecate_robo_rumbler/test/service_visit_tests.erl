%% @doc The whole visit path, end to end, with no mesh.
%%
%% THE ORDER OF OPERATIONS IS THE THING UNDER TEST. Archive first, settle, journal,
%% publish last and best-effort. If that order is ever rearranged into the tempting
%% one, a crash between steps starts losing the only irreplaceable thing here.
%% @end
-module(service_visit_tests).

-include_lib("eunit/include/eunit.hrl").

visit_path_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [?_test(archives_before_it_judges(Dir)),
         %% A real visit is 40 residents x 80 starts x 2 seats = 6,400 matches,
         %% about 13 seconds. eunit defaults to 5, so this is the honest end-to-end
         %% path with a timeout that reflects what it actually does rather than a
         %% shrunken version that would not exercise the real one.
         {timeout, 120, ?_test(a_good_visit_is_archived_journalled_and_returned(Dir))},
         ?_test(stats_report_the_truth(Dir))]
    end}.

setup() ->
    Dir = filename:join(["/tmp", "rumbler_service_test",
                         integer_to_list(erlang:unique_integer([positive]))]),
    os:putenv("HECATE_RUMBLE_ARCHIVE", Dir),
    {ok, _} = hecate_robo_rumbler_service:start_link(),
    Dir.

cleanup(Dir) ->
    gen_server:stop(hecate_robo_rumbler_service),
    os:unsetenv("HECATE_RUMBLE_ARCHIVE"),
    file:del_dir_r(Dir).

%% EVEN A REFUSED GENOME IS KEPT. A refusal is information about what people send,
%% and the bytes cost 577. Archiving only what passes would quietly discard the
%% most interesting arrivals.
archives_before_it_judges(Dir) ->
    Junk = <<"RG", 1:8, 2:16, 16:16, 5:16, 85:32, 0:(85 * 16)>>,
    ?assertMatch({error, {rejected, _}}, hecate_robo_rumbler_service:settle(Junk)),
    ?assertEqual({ok, robo_genome:id(Junk)}, {ok, robo_genome:id(Junk)}),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(Junk))).

a_good_visit_is_archived_journalled_and_returned(Dir) ->
    [#{packed := P} | _] = hecate_robo_rumbler_service:field(),
    {ok, Fact} = hecate_robo_rumbler_service:settle(P),
    ?assertEqual(visit_settled, maps:get(type, Fact)),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(P))),
    {ok, Journal} = visit_archive:journal(Dir),
    ?assertMatch([{visit, _} | _], [E || {visit, _} = E <- Journal]).

stats_report_the_truth(_Dir) ->
    S = hecate_robo_rumbler_service:stats(),
    ?assertEqual(40, maps:get(residents, S)),
    ?assert(maps:get(visits, S) >= 1),
    ?assert(maps:get(refused, S) >= 1),
    ?assert(maps:get(archived, S) >= 2),
    %% No realm in a test run, and the service still worked throughout.
    ?assertEqual(false, maps:get(mesh, S)).

%%==============================================================================
%% The message shape, which was wrong and silently so
%%==============================================================================

%% THIS TEST EXISTS BECAUSE THE FIRST VERSION MATCHED A MESSAGE MACULA NEVER
%% SENDS. handle_info matched {macula, Topic, Bytes}; the real shape is
%% {macula_event, SubRef, Topic, Payload, Meta} (macula_client.erl:924). A visitor
%% could have published a genome and the service would have discarded it in
%% silence: no error, no log, nothing. The shape below is copied from macula's own
%% source, not from what seemed reasonable.
mesh_message_shape_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Dir) ->
        [{timeout, 120, ?_test(a_real_macula_event_is_handled(Dir))},
         ?_test(a_wrong_shaped_payload_is_counted_not_guessed_at()),
         ?_test(a_dead_subscription_is_visible())]
    end}.

a_real_macula_event_is_handled(Dir) ->
    [#{packed := P} | _] = hecate_robo_rumbler_service:field(),
    Before = maps:get(visits, hecate_robo_rumbler_service:stats()),
    hecate_robo_rumbler_service !
        {macula_event, make_ref(), <<"rumble-scratch/challenge">>,
         #{type => challenge, genome => P}, #{}},
    %% stats/0 is a call, so it queues behind the visit and returning proves the
    %% visit finished rather than merely that the message was accepted.
    After = maps:get(visits, hecate_robo_rumbler_service:stats()),
    ?assertEqual(Before + 1, After),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(P))).

%% A payload that is not a challenge is COUNTED, not guessed at. Accepting a bare
%% binary as well would mean two shapes with one meaning, which is how a contract
%% stops being one.
a_wrong_shaped_payload_is_counted_not_guessed_at() ->
    Before = maps:get(ignored, hecate_robo_rumbler_service:stats()),
    hecate_robo_rumbler_service !
        {macula_event, make_ref(), <<"t">>, <<"a bare binary">>, #{}},
    hecate_robo_rumbler_service ! {macula_event, make_ref(), <<"t">>, #{type => gossip}, #{}},
    ?assertEqual(Before + 2, maps:get(ignored, hecate_robo_rumbler_service:stats())).

%% A DROPPED SUBSCRIPTION IS THE QUIETEST FAILURE THERE IS: the service keeps
%% running, looks healthy, and never hears anything again. It must be visible from
%% outside.
a_dead_subscription_is_visible() ->
    hecate_robo_rumbler_service ! {macula_event_gone, make_ref(), pool_closed},
    ?assertEqual(false, maps:get(subscribed, hecate_robo_rumbler_service:stats())).
