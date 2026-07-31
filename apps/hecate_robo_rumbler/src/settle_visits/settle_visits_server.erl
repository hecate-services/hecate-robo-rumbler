%% @doc The service: hold the field, hear a visitor, settle the visit.
%%
%% THREE RESPONSIBILITIES, SPLIT ON PURPOSE.
%%
%%   THIS SERVER owns the field and every write. It answers queries immediately
%%   and does no arithmetic, so a health check cannot queue behind a battle.
%%   THE WORKERS run the battle. It is pure integer simulation over immutable
%%   inputs, so it parallelises safely and needs no state at all.
%%   THE ARCHIVE is written only from here, so journal ordering is a property of
%%   this server's mailbox rather than a race between workers.
%%
%% WHY NOT SIMPLY A SECOND GEN_SERVER. It would fix the health check and give no
%% concurrency: a gen_server handles one message at a time, so the second visitor
%% would queue behind the first exactly as before. That moves the blocking rather
%% than removing it.
%%
%% THE ORDER OF OPERATIONS IS THE DESIGN, and it is not the obvious one.
%%
%%   1. ARCHIVE the genome, here, before a worker exists and before anything is
%%      judged. A visiting genome is a sample from an independently trained
%%      population that the research cannot otherwise obtain, so it is the one
%%      irreplaceable thing and every later step is allowed to fail.
%%   2. A WORKER settles the visit.
%%   3. Journal the row, here.
%%   4. PUBLISH last, best-effort. A dark mesh costs a fact, never a sample.
%%
%% BOUNDED CONCURRENCY, because the work is CPU-bound. Unbounded spawning turns
%% forty simultaneous visitors into forty processes contending for the same cores
%% and finishes none of them sooner. The excess QUEUES rather than being refused:
%% a visitor who waits still gets a row, a visitor who is refused is a sample lost.
%%
%% EVERYTHING IS KEYED BY WORKER PID. An earlier draft kept monitor references and
%% looked a finishing worker up by taking the head of the running set, which would
%% have completed the WRONG visit whenever two ran at once, answering one caller
%% with another's row. Exactly this front's recurring failure: no crash, a full
%% plausible result, about somebody else's contest.
-module(settle_visits_server).

-behaviour(gen_server).

-export([start_link/0, settle/1, field/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    field :: [resident_field:resident()],
    archive_dir :: file:filename_all(),
    sub :: reference() | undefined,
    %% Worker pid => {MonitorRef, who to answer}. `mesh' when nobody waits.
    running = #{} :: #{pid() => {reference(), gen_server:from() | mesh}},
    waiting = [] :: [{gen_server:from() | mesh, binary()}],
    limit = 1 :: pos_integer(),
    visits = 0 :: non_neg_integer(),
    refused = 0 :: non_neg_integer(),
    ignored = 0 :: non_neg_integer(),
    crashed = 0 :: non_neg_integer()
}).

%%==============================================================================
%% API
%%==============================================================================

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A full row is 6,400 matches, so the caller waits. It now waits on a WORKER
%% rather than on the server, which is the whole point of this version.
-spec settle(binary()) -> {ok, map()} | {error, term()}.
settle(Bytes) -> gen_server:call(?MODULE, {settle, Bytes}, 300000).

%% THESE ANSWER DURING A BATTLE. In the previous version they queued behind 13
%% seconds of arithmetic, which is survivable for a script and wrong for a health
%% endpoint.
-spec field() -> [resident_field:resident()].
field() -> gen_server:call(?MODULE, field).

-spec stats() -> map().
stats() -> gen_server:call(?MODULE, stats).

%%==============================================================================
%% gen_server
%%==============================================================================

init([]) -> started(archive_dir(), resident_field:load()).

started(_Dir, {error, Why}) -> {stop, {field_unusable, Why}};
started(Dir, {ok, Field}) ->
    %% THE MESH IS NOT UP YET AT THIS POINT AND THAT IS NOT AN ERROR. init/1 runs
    %% inside hecate_om:boot/2, which starts this service BEFORE its macula client
    %% is available. The first version subscribed here, once, and silently gave up
    %% when it failed. Booted against the live mesh it reported `mesh up: true'
    %% and `subscribed: false': connected, healthy-looking, and completely deaf.
    %% Only a real boot could have shown that.
    self() ! ensure_subscribed,
    {ok, #state{field = Field, archive_dir = Dir, limit = limit()}}.

%% ONE TIMER SOLVES BOTH RACES. It covers the boot ordering above and the
%% resubscribe after a dropped subscription, which was previously recorded as
%% owed. Cheap while connected (one map lookup), and the only thing that makes a
%% dropped subscription self-healing rather than merely visible.
-define(SUBSCRIBE_RETRY_MS, 5000).

ensure(#state{sub = Ref} = State) when Ref =/= undefined -> State;
ensure(#state{field = Field} = State) ->
    resubscribed(State, Field,
                 rumble_mesh:subscribe(visit_facts:topic(challenge), self())).

%% The field manifest is announced on every SUCCESSFUL (re)subscribe rather than
%% only at boot, because a subscriber that arrives after us has otherwise missed
%% the only manifest we ever sent and cannot read a single row.
resubscribed(State, Field, {ok, Ref}) ->
    ok = announce(Field),
    State#state{sub = Ref};
resubscribed(State, _Field, {error, _Why}) -> State.

announce(Field) ->
    _ = rumble_mesh:publish(visit_facts:topic(field), visit_facts:field_published(Field)),
    ok.

%% CPU-bound, so the natural cap is the scheduler count. Overridable because a
%% host sharing cores with other services will want fewer.
limit() -> configured_limit(os:getenv("HECATE_RUMBLE_CONCURRENCY")).

configured_limit(S) when is_list(S), S =/= "" -> max(1, list_to_integer(S));
configured_limit(_Unset) -> erlang:system_info(schedulers_online).

handle_call({settle, Bytes}, From, State) -> {noreply, accept(From, Bytes, State)};
handle_call(field, _From, State) -> {reply, State#state.field, State};
handle_call(stats, _From, State) -> {reply, snapshot(State), State};
handle_call(_Other, _From, State) -> {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% A challenge arriving over the mesh. The shape is macula's own,
%% {macula_event, SubRef, Topic, Payload, Meta} (macula_client.erl:924), taken
%% from that source rather than assumed: an earlier version matched a shape macula
%% never sends and would have discarded every challenge in silence.
handle_info({macula_event, _Ref, _Topic, Payload, _Meta}, State) ->
    {noreply, challenged(Payload, State)};

%% A dropped subscription is the quietest failure available: the service keeps
%% running, looks healthy, and never hears anything again.
handle_info({macula_event_gone, _Ref, _Reason}, State) ->
    {noreply, State#state{sub = undefined}};

%% Retry until subscribed, then keep ticking so a later drop is picked up.
handle_info(ensure_subscribed, State) ->
    erlang:send_after(?SUBSCRIBE_RETRY_MS, self(), ensure_subscribed),
    {noreply, ensure(State)};

%% A worker finished. THE WRITES HAPPEN HERE, never in the worker.
handle_info({settled, Pid, Result}, State) -> {noreply, finish(Pid, Result, State)};

%% A worker died. Answering is not optional: a caller blocked for five minutes on
%% a crashed battle is worse than an error.
handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    {noreply, died(Pid, Reason, State)};

handle_info(_Other, State) -> {noreply, State#state{ignored = State#state.ignored + 1}}.

%%==============================================================================
%% Admitting a visit
%%==============================================================================

%% THE CHALLENGE SHAPE IS A MAP, matching the facts this service publishes, so a
%% visitor can add fields later without changing what the message means. Anything
%% else is counted rather than guessed at: accepting a bare binary as well would
%% mean two shapes with one meaning.
challenged(#{type := challenge, genome := Bytes}, State) when is_binary(Bytes) ->
    accept(mesh, Bytes, State);
challenged(_Other, State) -> State#state{ignored = State#state.ignored + 1}.

accept(Who, Bytes, State) when is_binary(Bytes) ->
    %% STEP 1, AND IT IS FIRST FOR A REASON. On disk before it is judged, so even
    %% a genome this service goes on to REFUSE is kept: a refusal is information
    %% about what people send, and the bytes cost 577.
    _ = visit_archive:put_genome(State#state.archive_dir, Bytes),
    dispatch(Who, Bytes, State);
accept(Who, _NotBytes, State) ->
    answer(Who, {error, not_a_binary}),
    State#state{refused = State#state.refused + 1}.

%% At the cap the work QUEUES. Refusing would be cheaper and would throw away a
%% sample, which is the one thing this service exists not to do.
dispatch(Who, Bytes, #state{running = R, limit = L} = State) when map_size(R) >= L ->
    State#state{waiting = State#state.waiting ++ [{Who, Bytes}]};
dispatch(Who, Bytes, State) ->
    {Pid, Ref} = spawn_worker(Bytes, State#state.field),
    State#state{running = maps:put(Pid, {Ref, Who}, State#state.running)}.

%% THE WORKER IS PURE. No state, no disk, no publishing: immutable inputs in, one
%% message out. That is what makes running several at once safe, and it is why
%% the archive writes stayed behind in the server.
spawn_worker(Bytes, Field) ->
    Parent = self(),
    spawn_monitor(fun() -> Parent ! {settled, self(), settle_visits:settle(Bytes, Field)} end).

%%==============================================================================
%% Finishing
%%==============================================================================

finish(Pid, Result, #state{running = R} = State) ->
    completed(maps:get(Pid, R, undefined), Pid, Result, State).

%% Not ours, or already finished. Neither is an error.
completed(undefined, _Pid, _Result, State) -> State;
completed({Ref, Who}, Pid, Result, #state{running = R} = State) ->
    %% Demonitor with flush, so the DOWN that follows a normal exit never arrives
    %% to be mistaken for a crash.
    true = erlang:demonitor(Ref, [flush]),
    {Reply, State2} = record(Result, State),
    answer(Who, Reply),
    next(State2#state{running = maps:remove(Pid, R)}).

%% STEP 3 AND 4, both here and in this order: durable locally, then best-effort
%% outward.
%%
%% THE CALLER IS ANSWERED WITH THE FACT, NOT THE INTERNAL ROW. They are different
%% shapes and only one of them is a contract. The first version of this refactor
%% returned the row, so a caller silently began receiving a different structure
%% than the mesh does. A test caught it; nothing else would have.
record({error, _Why} = E, State) -> {E, State#state{refused = State#state.refused + 1}};
record({ok, Row}, State) ->
    Fact = visit_facts:visit_settled(Row, State#state.field),
    _ = visit_archive:append(State#state.archive_dir, {visit, Fact}),
    _ = rumble_mesh:publish(visit_facts:topic(visit), Fact),
    {{ok, Fact}, State#state{visits = State#state.visits + 1}}.

died(Pid, Reason, #state{running = R} = State) ->
    dead(maps:get(Pid, R, undefined), Pid, Reason, State).

dead(undefined, _Pid, _Reason, State) -> State;
dead({_Ref, Who}, Pid, Reason, #state{running = R} = State) ->
    answer(Who, {error, {battle_crashed, Reason}}),
    next(State#state{running = maps:remove(Pid, R),
                     crashed = State#state.crashed + 1}).

next(#state{waiting = []} = State) -> State;
next(#state{waiting = [{Who, Bytes} | Rest]} = State) ->
    dispatch(Who, Bytes, State#state{waiting = Rest}).

answer(mesh, _Result) -> ok;
answer(From, Result) -> gen_server:reply(From, Result).

%%==============================================================================
%% Reporting
%%==============================================================================

snapshot(State) ->
    #{residents => length(State#state.field),
      visits => State#state.visits,
      refused => State#state.refused,
      ignored => State#state.ignored,
      crashed => State#state.crashed,
      running => map_size(State#state.running),
      %% WHICH battles, not merely how many. An operator watching a wedged visit
      %% needs the pid to inspect, and a test needs it to exercise the crash path
      %% precisely instead of killing whatever happens to be nearby.
      running_pids => maps:keys(State#state.running),
      waiting => length(State#state.waiting),
      concurrency_limit => State#state.limit,
      archived => visit_archive:genome_count(State#state.archive_dir),
      journal => visit_archive:journal_count(State#state.archive_dir),
      mesh => rumble_mesh:available(),
      subscribed => State#state.sub =/= undefined}.

archive_dir() -> configured_dir(os:getenv("HECATE_RUMBLE_ARCHIVE")).

configured_dir(D) when is_list(D), D =/= "" -> D;
configured_dir(_Unset) -> filename:join(["/var", "lib", "hecate-robo-rumbler"]).
