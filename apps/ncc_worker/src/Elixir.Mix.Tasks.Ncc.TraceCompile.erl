-module('Elixir.Mix.Tasks.Ncc.TraceCompile').
%% `mix ncc.trace_compile`: the worker's traced judge compile (precompiled
%% portability spec, R1). Starts ncc_tracer, then recompiles the closure of
%% NCC_TRACE_PACKAGE one dependency at a time with
%% Mix.Tasks.Deps.Compile.compile_single/3, each inside a window the task
%% opens and closes itself, with the sentinel fired inside it. Written in
%% Erlang so the worker app needs no :mix dependency; Mix finds it by name.
%%
%% The tracer's token lives only in this module's variables and arguments:
%% never in the process dictionary, persistent_term, an application env or
%% an ETS table, all of which a package's compile-time code can read
%% untraced. Its stack can only be read through process_info, which the
%% tracer patterns as an integrity event.
%%
%% start_main/0 runs before anything compiles: it loads the module of every
%% pattern while the code path is still the whole OTP install. Mix prunes the
%% code path to a dependency's own applications before compiling it, but a
%% loaded module stays loaded and traced.
-export([run/1, '__info__'/1]).

%% Mix reads module.__info__(:attributes) for @shortdoc, @recursive and
%% @requirements; this task has none of them.
'__info__'(_Kind) -> [].

run(_Args) ->
    Packages = names("NCC_TRACE_PACKAGE"),
    Native = names("NCC_TRACE_NATIVE"),
    case ncc_tracer:start_main() of
        {ok, Token} -> traced(Token, Packages, Native);
        {error, _Why} -> erlang:exit({shutdown, 1})
    end.

traced(Token, Packages, Native) ->
    %% First, before Mix.Dep.load_and_cache/0 evaluates any dependency's
    %% mix.exs and before anything compiles: no package code has run in this
    %% VM yet, so the env is the one the project's config left (spec R5,
    %% ncc_tracer_config). The report refuses a trace without it, with two,
    %% or with one written after the closure line.
    _ = ncc_tracer:config_env(Token, ncc_tracer_config:snapshot()),
    Config = 'Elixir.Mix.Project':config(),
    case with_build_lock(Config, fun() -> compile(Token, Packages, Native) end) of
        ok ->
            _ = ncc_tracer:finish(Token, ok),
            ok;
        {not_in_closure, Missing} ->
            _ = ncc_tracer:finish(Token, package_not_in_closure),
            io:format(standard_error, "ncc.trace_compile: not in the project's dependencies: ~ts~n",
                      [lists:join(", ", [atom_to_list(M) || M <- Missing])]),
            erlang:exit({shutdown, 1});
        {failed, Class, Reason, Stack} ->
            _ = ncc_tracer:finish(Token, compile_failed),
            erlang:raise(Class, Reason, Stack)
    end.

%% Unlike `mix deps.compile`, no `deps.precompile`: it is a hook, a no-op in a
%% plain project, and in a full run's Nerves project nerves_bootstrap aliases
%% it to work that would run package code outside every window.
compile(Token, Packages, Native) ->
    try
        Deps = 'Elixir.Mix.Dep':load_and_cache(),
        case resolve(Packages, Deps) of
            {ok, Apps} -> compile_closure(Token, Apps, Deps, Native);
            {error, Missing} -> {not_in_closure, Missing}
        end
    catch
        Class:Reason:Stack -> {failed, Class, Reason, Stack}
    end.

compile_closure(Token, Apps, Deps, Native) ->
    Ordered = closure_order(Apps, Deps),
    _ = ncc_tracer:closure(Token, Apps, [dep_info(D) || D <- Ordered]),
    DepConfig = 'Elixir.Mix.Project':deps_config(),
    lists:foreach(fun(D) -> compile_dep(Token, D, Native, DepConfig) end, Ordered).

%% Each requested package as the OTP app of one of the project's
%% dependencies: by app name, else by the Hex package name in the
%% dependency's `:hex` option (a package whose name is not its app's). No
%% package, or one that is no dependency, is an error: nothing is compiled
%% and the trace ends `package_not_in_closure`, never a clean, empty trace.
resolve([], _Deps) -> {error, []};
resolve(Names, Deps) ->
    Found = [{Name, app_of(Name, Deps)} || Name <- Names],
    case [Name || {Name, none} <- Found] of
        [] -> {ok, lists:uniq([App || {_, App} <- Found])};
        Missing -> {error, Missing}
    end.

app_of(Name, Deps) ->
    ByApp = [maps:get(app, D) || D <- Deps, maps:get(app, D) =:= Name],
    ByHex = [maps:get(app, D) || D <- Deps, hex_name(D) =:= Name],
    case ByApp ++ ByHex of
        [App | _] -> App;
        [] -> none
    end.

hex_name(Dep) ->
    case opt(hex, Dep) of
        undefined -> {no_hex_name};
        Name when is_atom(Name) -> Name;
        Name when is_binary(Name) -> binary_to_atom(Name);
        Name when is_list(Name) -> list_to_atom(Name);
        _ -> {no_hex_name}
    end.

compile_dep(Token, Dep, Native, DepConfig) ->
    App = maps:get(app, Dep),
    _ = ncc_tracer:window_open(Token, App),
    _ = ncc_tracer:fire(App),
    _ = 'Elixir.Mix.Tasks.Deps.Compile':compile_single(Dep, true, DepConfig),
    _ = ncc_tracer:window_close(Token, App),
    _ = ncc_tracer:built(Token, App, opt(build, Dep)),
    case lists:member(App, Native) of
        true ->
            Ebin = filename:join(opt(build, Dep), "ebin"),
            _ = ncc_tracer:native_patterns(Token, App, Ebin),
            ok;
        false -> ok
    end.

%% The packages and everything they reach, in Mix's compile order.
closure_order(Packages, Deps) ->
    ByApp = maps:from_list([{maps:get(app, D), D} || D <- Deps]),
    Wanted = reach(Packages, ByApp, #{}),
    [D || D <- Deps, is_map_key(maps:get(app, D), Wanted)].

reach([], _ByApp, Seen) -> Seen;
reach([App | Rest], ByApp, Seen) when is_map_key(App, Seen) -> reach(Rest, ByApp, Seen);
reach([App | Rest], ByApp, Seen) ->
    Children = case ByApp of
                   #{App := Dep} -> [maps:get(app, C) || C <- maps:get(deps, Dep)];
                   _ -> []
               end,
    reach(Children ++ Rest, ByApp, Seen#{App => true}).

dep_info(Dep) ->
    #{app => maps:get(app, Dep), dest => text(opt(dest, Dep)), build => text(opt(build, Dep)),
      manager => text(maps:get(manager, Dep)),
      children => [maps:get(app, C) || C <- maps:get(deps, Dep)]}.

opt(Key, Dep) -> proplists:get_value(Key, maps:get(opts, Dep)).

text(undefined) -> null;
text(nil) -> null;
text(Atom) when is_atom(Atom) -> atom_to_binary(Atom);
text(Path) -> unicode:characters_to_binary(Path).

with_build_lock(Config, Fun) ->
    case erlang:function_exported('Elixir.Mix.Project', with_build_lock, 2) of
        true -> 'Elixir.Mix.Project':with_build_lock(Config, Fun);
        false -> Fun()
    end.

names(Var) -> [list_to_atom(Name) || Name <- string:lexemes(os:getenv(Var, ""), ",")].
