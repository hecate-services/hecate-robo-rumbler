#!/usr/bin/env escript
%%! -escript main visit
%%
%% A VISITOR. Sends one tank to a rumbler over the mesh and waits for the row.
%%
%% This is the other half of the loop and the first thing a person can actually
%% run. It joins the same realm, subscribes to the result topic, publishes a
%% challenge, and prints what comes back.
%%
%% Usage:
%%   scripts/visit.escript <genome-file> [seconds-to-wait]
%%
%% The genome file is the packed wire format from robo_genome:pack/1. Any of the
%% resident champions works as a first visitor.

main([Path]) -> main([Path, "120"]);
main([Path, WaitS]) ->
    {ok, Bytes} = file:read_file(Path),
    io:format("visitor  : ~p bytes~n", [byte_size(Bytes)]),
    ok = boot(),
    Topic = visit_facts:topic(visit),
    %% RETRY, BECAUSE A POOL EXISTING IS NOT A STATION BEING READY. The first
    %% version subscribed once and died on {transient, no_healthy_station}: the
    %% client attaches before any station link is healthy. Exactly the bug just
    %% fixed in the server, not applied here until it bit.
    ok = retry(fun() -> macula:subscribe(pool(), realm(), Topic, self()) end,
               "subscribe", 60),
    io:format("listening: ~s~n", [Topic]),
    ok = retry(fun() -> macula:publish(pool(), realm(), visit_facts:topic(challenge),
                                       #{type => challenge, genome => Bytes}) end,
               "publish", 60),
    io:format("sent     : ~s~n~nwaiting for a row...~n",
              [visit_facts:topic(challenge)]),
    await(robo_genome:id(Bytes), list_to_integer(WaitS) * 1000),
    halt(0);
main(_) ->
    io:format("usage: visit.escript <genome-file> [seconds]~n"),
    halt(1).

retry(_F, What, 0) -> io:format("gave up on ~s~n", [What]), error({gave_up, What});
retry(F, What, N) -> retried(F, What, N, catch F()).

retried(_F, _What, _N, ok) -> ok;
retried(_F, _What, _N, {ok, _}) -> ok;
retried(F, What, N, _NotYet) -> timer:sleep(1000), retry(F, What, N - 1).

%% Wait for OUR row specifically. Any rumbler on this topic publishes every row it
%% settles, so matching on the challenger id is what stops a busy topic being
%% mistaken for an answer to us.
await(Id, Timeout) ->
    Want = binary:encode_hex(Id),
    receive
        {macula_event, _Ref, _T, #{type := visit_settled, challenger_id := Want} = Row, _M} ->
            report(Row);
        {macula_event, _Ref, _T, _Other, _M} ->
            await(Id, Timeout)
    after Timeout ->
        io:format("~nno row within the timeout. The rumbler may be busy, or "
                  "nothing is listening on the challenge topic.~n")
    end.

report(Row) ->
    io:format("~n=== ROW ===~n"),
    io:format("opponents : ~p~n", [maps:get(opponents, Row)]),
    io:format("matches   : ~p~n", [maps:get(matches, Row)]),
    io:format("won       : ~p~n", [maps:get(wins, Row)]),
    io:format("lost      : ~p~n", [maps:get(losses, Row)]),
    io:format("drawn     : ~p~n", [maps:get(draws, Row)]),
    io:format("turn-cap  : ~p~n", [maps:get(capped, Row)]),
    io:format("field     : ~s~n", [maps:get(field_id, Row)]),
    io:format("engine    : ~s~n", [maps:get(engine_id, Row)]),
    io:format("starts    : ~p~n", [maps:get(start_set, Row)]).

boot() ->
    application:load(hecate_om),
    application:set_env(hecate_om, health_port, undefined),
    application:set_env(hecate_om, realm, realm_hex()),
    {ok, _} = application:ensure_all_started(hecate_om),
    wait_for_mesh(60).

wait_for_mesh(0) -> {error, mesh_never_came_up};
wait_for_mesh(N) ->
    case catch hecate_om:macula_client() of
        {ok, _} -> ok;
        _NotYet -> timer:sleep(500), wait_for_mesh(N - 1)
    end.

pool() -> element(2, hecate_om:macula_client()).

realm() -> element(2, hecate_om_identity:realm()).

realm_hex() ->
    case os:getenv("HECATE_REALM") of
        S when is_list(S), S =/= "" -> list_to_binary(S);
        _Unset -> error(no_realm_set)
    end.
