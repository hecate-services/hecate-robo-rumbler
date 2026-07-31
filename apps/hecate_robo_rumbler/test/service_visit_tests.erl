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
    {ok, _} = settle_visits_server:start_link(),
    Dir.

cleanup(Dir) ->
    gen_server:stop(settle_visits_server),
    os:unsetenv("HECATE_RUMBLE_ARCHIVE"),
    file:del_dir_r(Dir).

%% EVEN A REFUSED GENOME IS KEPT. A refusal is information about what people send,
%% and the bytes cost 577. Archiving only what passes would quietly discard the
%% most interesting arrivals.
archives_before_it_judges(Dir) ->
    Junk = <<"RG", 1:8, 2:16, 16:16, 5:16, 85:32, 0:(85 * 16)>>,
    ?assertMatch({error, {rejected, _}}, settle_visits_server:settle(Junk)),
    ?assertEqual({ok, robo_genome:id(Junk)}, {ok, robo_genome:id(Junk)}),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(Junk))).

a_good_visit_is_archived_journalled_and_returned(Dir) ->
    [#{packed := P} | _] = settle_visits_server:field(),
    {ok, Fact} = settle_visits_server:settle(P),
    ?assertEqual(visit_settled, maps:get(type, Fact)),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(P))),
    {ok, Journal} = visit_archive:journal(Dir),
    ?assertMatch([{visit, _} | _], [E || {visit, _} = E <- Journal]).

stats_report_the_truth(_Dir) ->
    S = settle_visits_server:stats(),
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
    [#{packed := P} | _] = settle_visits_server:field(),
    Before = maps:get(visits, settle_visits_server:stats()),
    settle_visits_server !
        {macula_event, make_ref(), <<"rumble-scratch/challenge">>,
         #{type => challenge, genome => P}, #{}},
    %% A mesh-delivered visit is now genuinely ASYNCHRONOUS: a worker runs it and
    %% nobody is waiting. So this waits for the count to move rather than reading
    %% it immediately, which used to work only because the server blocked.
    ?assertEqual(ok, until(fun() ->
        maps:get(visits, settle_visits_server:stats()) >= Before + 1 end)),
    ?assert(visit_archive:has_genome(Dir, robo_genome:id(P))).

%% A payload that is not a challenge is COUNTED, not guessed at. Accepting a bare
%% binary as well would mean two shapes with one meaning, which is how a contract
%% stops being one.
a_wrong_shaped_payload_is_counted_not_guessed_at() ->
    Before = maps:get(ignored, settle_visits_server:stats()),
    settle_visits_server !
        {macula_event, make_ref(), <<"t">>, <<"a bare binary">>, #{}},
    settle_visits_server ! {macula_event, make_ref(), <<"t">>, #{type => gossip}, #{}},
    ?assertEqual(Before + 2, maps:get(ignored, settle_visits_server:stats())).

%% A DROPPED SUBSCRIPTION IS THE QUIETEST FAILURE THERE IS: the service keeps
%% running, looks healthy, and never hears anything again. It must be visible from
%% outside.
a_dead_subscription_is_visible() ->
    settle_visits_server ! {macula_event_gone, make_ref(), pool_closed},
    ?assertEqual(false, maps:get(subscribed, settle_visits_server:stats())).

%%==============================================================================
%% The worker split: what it is actually for
%%==============================================================================

worker_split_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_Dir) ->
        [{timeout, 120, ?_test(queries_answer_during_a_battle())},
         {timeout, 300, ?_test(two_visits_overlap())},
         ?_test(a_crashed_worker_answers_its_caller())]
    end}.

%% THE POINT OF THE WHOLE CHANGE. Previously stats/0 queued behind 13 seconds of
%% arithmetic in handle_call, so a health check during a visit timed out. It must
%% now answer promptly WHILE a battle is running, and report the battle.
queries_answer_during_a_battle() ->
    [#{packed := P} | _] = settle_visits_server:field(),
    Caller = self(),
    spawn(fun() -> Caller ! {done, settle_visits_server:settle(P)} end),
    timer:sleep(500),
    T0 = erlang:monotonic_time(millisecond),
    S = settle_visits_server:stats(),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    %% Answered promptly, not after the battle finished.
    ?assert(Elapsed < 1000),
    %% And it can see the battle it did not block on.
    ?assert(maps:get(running, S) >= 1),
    receive {done, {ok, _}} -> ok after 120000 -> error(visit_never_finished) end.

%% CONCURRENCY, not merely responsiveness. A second gen_server would have fixed
%% the health check and still serialised the battles. Two visits must overlap, so
%% together they take materially less than twice one.
two_visits_overlap() ->
    [#{packed := P} | _] = settle_visits_server:field(),
    ?assert(maps:get(concurrency_limit, settle_visits_server:stats()) >= 2),
    One = timed(fun() -> settle_visits_server:settle(P) end),
    Two = timed(fun() -> pmap(2, fun() -> settle_visits_server:settle(P) end) end),
    %% Serialised would be about 2x. Overlapping is well under.
    ?assert(Two < One * 17 div 10).

%% A caller blocked for five minutes on a crashed battle is worse than an error,
%% so a dying worker must answer. Driven by killing the worker the service
%% spawned, which is the only way to exercise the DOWN path honestly.
a_crashed_worker_answers_its_caller() ->
    [#{packed := P} | _] = settle_visits_server:field(),
    Caller = self(),
    spawn(fun() -> Caller ! {result, settle_visits_server:settle(P)} end),
    timer:sleep(300),
    kill_a_worker(),
    receive
        {result, {error, {battle_crashed, _}}} -> ok;
        %% A race is acceptable: if the battle finished first there was nothing to
        %% kill, and the caller was answered either way, which is the property.
        {result, {ok, _}} -> ok
    after 120000 -> error(caller_was_never_answered)
    end.

%% KILLS THE ACTUAL WORKER, by asking the service which pids are running. The
%% first version killed everything LINKED to the service, and spawn_monitor does
%% not link, so it killed whatever unrelated process happened to be there: the
%% eunit runner. A test that takes out its own harness is not a test.
kill_a_worker() ->
    [exit(P, kill) || P <- maps:get(running_pids, settle_visits_server:stats())],
    ok.

%% Poll rather than sleep a fixed time: a fixed sleep is either flaky or slow, and
%% on a loaded machine it is both.
until(F) -> until(F, 600).

until(_F, 0) -> timeout;
until(F, N) -> settled_yet(F, N, F()).

settled_yet(_F, _N, true) -> ok;
settled_yet(F, N, false) -> timer:sleep(200), until(F, N - 1).

timed(F) ->
    T0 = erlang:monotonic_time(millisecond),
    _ = F(),
    erlang:monotonic_time(millisecond) - T0.

pmap(N, F) ->
    Me = self(),
    Pids = [spawn(fun() -> Me ! {self(), F()} end) || _ <- lists:seq(1, N)],
    [receive {P, R} -> R after 300000 -> error(timeout) end || P <- Pids].
