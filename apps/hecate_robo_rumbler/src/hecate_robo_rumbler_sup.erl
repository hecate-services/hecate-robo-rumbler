%% @doc Supervises the one process this service has.
%%
%% ONE CHILD, because there is one job. The battle workers are spawned by that
%% child and monitored rather than supervised: they are transient pure
%% computations, not services, and restarting a dead battle would re-run a visit
%% whose caller has already been answered with the crash.
-module(hecate_robo_rumbler_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => settle_visits_server,
             start => {settle_visits_server, start_link, []},
             restart => permanent,
             shutdown => 30000,
             type => worker}]}}.
