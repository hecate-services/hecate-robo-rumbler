%% @doc OTP application entry.
%%
%% hecate_om:boot/2 wires the mesh, the realm identity and health, then starts
%% this service. STORELESS: no store_id/0 or data_dir/0 callback, so no reckon-db
%% is started. This service keeps a flat content-addressed archive of its own,
%% because the plan's tier table says an embedded store earns its place at ranked
%% visits and there is no ranking here yet.
-module(hecate_robo_rumbler_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> hecate_om:boot(hecate_robo_rumbler_service).

stop(_State) -> ok.
