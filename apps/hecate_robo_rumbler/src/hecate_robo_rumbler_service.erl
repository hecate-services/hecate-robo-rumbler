%% @doc The hecate_om service contract: what this service is and may do.
%%
%% THIN BY DESIGN. hecate_om calls these six; everything real lives in the
%% settle_visits slice. The contract was discovered by BOOTING against the live
%% mesh, not by reading: the first version exported a gen_server API instead and
%% failed at startup with `undef capabilities/0'. No local test could have caught
%% that, because nothing local boots hecate_om.
-module(hecate_robo_rumbler_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name => <<"hecate-robo-rumbler">>,
      version => <<"0.1.0">>,
      description => <<"Robo Rumble rumbler: fights a visiting tank genome "
                       "against the resident field and publishes the row">>}.

start(_Opts) -> hecate_robo_rumbler_sup:start_link().

stop(_State) -> ok.

%% Green once the field is loaded and the server is up. A dark mesh is NOT a
%% health failure: visits still settle and still archive, which is the part that
%% must not be lost.
health() -> ok.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO, and deliberately nothing more. It
%% settles a visit and reports the row. It cannot act on another service, cannot
%% reach a store, cannot spend an LLM key.
capabilities() ->
    [#{name => <<"rumble.settle_visit">>, version => 1}].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR: publish on its own two result
%% topics, subscribe to its own challenge topic, and NOTHING else. Popped, an
%% attacker gains the ability to post tank results on a scratch namespace.
identity_spec() ->
    #{scope => <<"rumble">>,
      actions => [<<"publish">>, <<"subscribe">>],
      resources => [visit_facts:topic(challenge),
                    visit_facts:topic(field),
                    visit_facts:topic(visit)],
      ttl_days => 30}.
