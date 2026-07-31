%% @doc The service: hold the field, hear a visitor, settle the visit.
%%
%% THE ORDER OF OPERATIONS IS THE DESIGN, and it is not the obvious one.
%%
%%   1. ARCHIVE the genome. Before anything else, before the battle, before any
%%      publish. The archive is why this service exists: a visiting genome is a
%%      sample from an independently trained population that the research cannot
%%      otherwise obtain. Everything after this step can fail without losing it.
%%   2. Settle the visit, which is minutes of arithmetic and cannot fail in a way
%%      that costs data.
%%   3. Journal the row, locally and durably.
%%   4. PUBLISH last, and best-effort. A dark mesh must never cost a sample.
%%
%% Doing it in the tempting order, battle then publish then maybe archive, means a
%% crash or a full disk between steps loses the one thing that was irreplaceable.
%%
%% BOOT PUBLISHES THE FIELD, ONCE. Rows carry only a field_id, so a subscriber
%% needs the manifest to join against. Publishing it per row would haul forty
%% manifests every visit; publishing it never would make every row unreadable.
%%
%% THE FIELD IS VALIDATED AT BOOT AND THE SERVICE REFUSES TO START WITHOUT IT. A
%% resident that fails the wire contract is a broken build, not a runtime
%% surprise to discover during someone's visit.
-module(hecate_robo_rumbler_service).

-behaviour(gen_server).

-export([start_link/0, settle/1, field/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    field :: [resident_field:resident()],
    archive_dir :: file:filename_all(),
    sub :: reference() | undefined,
    visits = 0 :: non_neg_integer(),
    refused = 0 :: non_neg_integer(),
    ignored = 0 :: non_neg_integer()
}).

%%==============================================================================
%% API
%%==============================================================================

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Settle a visit synchronously. Exposed so a visit can be driven without the
%% mesh, which is how the whole path is tested.
%%
%% The timeout is generous because a full row is 6,400 matches. The compute
%% budget in settle_visits is what stops that becoming unbounded, so this is a
%% backstop rather than the actual protection.
-spec settle(binary()) -> {ok, map()} | {error, term()}.
settle(Bytes) -> gen_server:call(?MODULE, {settle, Bytes}, 300000).

-spec field() -> [resident_field:resident()].
field() -> gen_server:call(?MODULE, field, 300000).

%% HEAD-OF-LINE BLOCKING IS REAL HERE AND IS NOT YET FIXED. A visit is about 13
%% seconds of pure CPU inside handle_call, so stats/0 and every other call queue
%% behind it. That is tolerable for a v1 that settles one visit at a time and it
%% is NOT tolerable for a health endpoint, which is what this becomes in
%% production. The timeout below makes the queueing survivable rather than
%% correct; the actual fix is to settle in a spawned process and reply
%% asynchronously, which changes the API and is owed.
-spec stats() -> map().
stats() -> gen_server:call(?MODULE, stats, 300000).

%%==============================================================================
%% gen_server
%%==============================================================================

init([]) ->
    Dir = archive_dir(),
    started(Dir, resident_field:load()).

started(_Dir, {error, Why}) -> {stop, {field_unusable, Why}};
started(Dir, {ok, Field}) ->
    ok = announce(Field),
    {ok, #state{field = Field, archive_dir = Dir, sub = listen()}}.

%% SUBSCRIBE, WHICH THE FIRST VERSION SIMPLY DID NOT DO. It published the field
%% and then waited for messages it had never asked for, so a visitor could send a
%% genome and nothing at all would happen: no error, no log, silence. Best-effort
%% like the publish, because a dark mesh at boot is normal, and the reference is
%% kept so a dropped subscription is recognisable rather than merely quiet.
listen() ->
    subscribed(rumble_mesh:subscribe(visit_facts:topic(challenge), self())).

subscribed({ok, Ref}) -> Ref;
subscribed({error, _Why}) -> undefined.

%% The manifest, best-effort. A dark mesh at boot is normal and must not stop the
%% service: visits still settle and still archive, and the field is re-announced
%% the next time the service starts.
announce(Field) ->
    Fact = visit_facts:field_published(Field),
    _ = rumble_mesh:publish(visit_facts:topic(field), Fact),
    ok.

handle_call({settle, Bytes}, _From, State) ->
    {Reply, State2} = visit(Bytes, State),
    {reply, Reply, State2};
handle_call(field, _From, State) ->
    {reply, State#state.field, State};
handle_call(stats, _From, State) ->
    {reply, #{residents => length(State#state.field),
              visits => State#state.visits,
              refused => State#state.refused,
              ignored => State#state.ignored,
              archived => visit_archive:genome_count(State#state.archive_dir),
              journal => visit_archive:journal_count(State#state.archive_dir),
              mesh => rumble_mesh:available(),
              %% A live subscription is the difference between a service that can
              %% hear a visitor and one that only looks like it can.
              subscribed => State#state.sub =/= undefined}, State};
handle_call(_Other, _From, State) -> {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% A CHALLENGE ARRIVING OVER THE MESH. The shape is macula's own:
%% {macula_event, SubRef, Topic, Payload, Meta}. The first version matched
%% {macula, Topic, Bytes}, which macula never sends, so every challenge would have
%% fallen through to the catch-all and been discarded in silence. The shape is
%% taken from macula_client.erl:924 rather than assumed.
%%
%% Fire and forget from the sender's view: the row comes back as a published fact,
%% not as a reply, because the sender may be long gone by the time 6,400 matches
%% are finished.
handle_info({macula_event, _Ref, _Topic, Payload, _Meta}, State) ->
    {noreply, challenged(Payload, State)};

%% THE SUBSCRIPTION DIED. Without this the service keeps running, looks healthy,
%% and receives nothing ever again, which is the quietest possible failure. There
%% is no resubscribe loop yet and that is stated rather than implied: the count is
%% surfaced in stats/0 so a dead subscription is visible from outside.
handle_info({macula_event_gone, _Ref, _Reason}, State) ->
    {noreply, State#state{sub = undefined}};

handle_info(_Other, State) ->
    {noreply, State#state{ignored = State#state.ignored + 1}}.

%% THE CHALLENGE SHAPE IS A MAP, matching the facts this service publishes, so a
%% visitor can add fields later without the meaning of the message changing.
%% Anything else is counted rather than guessed at: accepting a bare binary too
%% would mean two shapes with one meaning, which is how a contract stops being one.
challenged(#{type := challenge, genome := Bytes}, State) when is_binary(Bytes) ->
    element(2, visit(Bytes, State));
challenged(_Other, State) ->
    State#state{ignored = State#state.ignored + 1}.

%%==============================================================================
%% One visit, in the order that cannot lose a sample
%%==============================================================================

visit(Bytes, State) when is_binary(Bytes) ->
    %% STEP 1, AND IT IS FIRST FOR A REASON. Archived before it is judged, so
    %% even a genome the service goes on to REFUSE is kept: a refusal is itself
    %% information about what people are sending, and the bytes cost 577.
    _ = visit_archive:put_genome(State#state.archive_dir, Bytes),
    settled(Bytes, State, settle_visits:settle(Bytes, State#state.field));
visit(_NotBytes, State) ->
    {{error, not_a_binary}, State#state{refused = State#state.refused + 1}}.

settled(_Bytes, State, {error, _Why} = E) ->
    {E, State#state{refused = State#state.refused + 1}};
settled(_Bytes, State, {ok, Row}) ->
    Fact = visit_facts:visit_settled(Row, State#state.field),
    %% STEP 3 before STEP 4: durable locally, then best-effort outward.
    _ = visit_archive:append(State#state.archive_dir, {visit, Fact}),
    _ = rumble_mesh:publish(visit_facts:topic(visit), Fact),
    {{ok, Fact}, State#state{visits = State#state.visits + 1}}.

archive_dir() ->
    case os:getenv("HECATE_RUMBLE_ARCHIVE") of
        D when is_list(D), D =/= "" -> D;
        _Unset -> filename:join(["/var", "lib", "hecate-robo-rumbler"])
    end.
