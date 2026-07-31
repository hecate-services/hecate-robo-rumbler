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
    visits = 0 :: non_neg_integer(),
    refused = 0 :: non_neg_integer()
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
field() -> gen_server:call(?MODULE, field).

-spec stats() -> map().
stats() -> gen_server:call(?MODULE, stats).

%%==============================================================================
%% gen_server
%%==============================================================================

init([]) ->
    Dir = archive_dir(),
    started(Dir, resident_field:load()).

started(_Dir, {error, Why}) -> {stop, {field_unusable, Why}};
started(Dir, {ok, Field}) ->
    ok = announce(Field),
    {ok, #state{field = Field, archive_dir = Dir}}.

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
              archived => visit_archive:genome_count(State#state.archive_dir),
              journal => visit_archive:journal_count(State#state.archive_dir),
              mesh => rumble_mesh:available()}, State};
handle_call(_Other, _From, State) -> {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% A genome arriving over the mesh. Fire and forget from the sender's view: the
%% row goes back as a published fact, not as a reply, because the sender may be
%% gone by the time a 6,400-match row is finished.
handle_info({macula, _Topic, Bytes}, State) when is_binary(Bytes) ->
    {_Reply, State2} = visit(Bytes, State),
    {noreply, State2};
handle_info(_Other, State) -> {noreply, State}.

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
