-module('Elixir.Mix.Tasks.Ncc.NervesEnv').
%% `mix ncc.nerves_env <out>`: the environment Nerves's Mix integration sets
%% up for a target's compile (NccWorker.FirmwareInputs). Runs the project's
%% `deps.loadpaths` without compiling anything: nerves_bootstrap puts
%% Nerves's own env setup in front of it (`nerves_bootstrap.init` under
%% Nerves 2, `nerves.bootstrap` and `nerves.loadpaths` under Nerves 1), the
%% same steps `mix firmware` runs before it compiles a dependency. Then
%% writes every variable those steps added or changed to <out>, as
%% `Name NUL Value NUL` for each (no variable holds a NUL). Written in Erlang
%% so the worker app needs no :mix dependency; Mix finds it by name.
-export([run/1, '__info__'/1]).

%% Mix reads module.__info__(:attributes) for @shortdoc, @recursive and
%% @requirements; this task has none of them.
'__info__'(_Kind) -> [].

run([Out]) when is_binary(Out) ->
    Before = maps:from_list(env()),
    _ = 'Elixir.Mix.Task':run(<<"deps.loadpaths">>, [<<"--no-deps-check">>, <<"--no-compile">>]),
    Changed = [{Name, Value} || {Name, Value} <- env(), maps:get(Name, Before, none) =/= Value],
    ok = file:write_file(Out, [[Name, 0, Value, 0] || {Name, Value} <- Changed]);
run(_Args) ->
    erlang:exit({shutdown, 2}).

%% Every variable whose name and value are both UTF-8.
env() ->
    lists:filtermap(fun entry/1, os:getenv()).

entry(Entry) ->
    case lists:splitwith(fun(C) -> C =/= $= end, Entry) of
        {[_ | _] = Name, [$= | Value]} ->
            case {unicode:characters_to_binary(Name), unicode:characters_to_binary(Value)} of
                {N, V} when is_binary(N), is_binary(V) -> {true, {N, V}};
                _ -> false
            end;
        _ -> false
    end.
