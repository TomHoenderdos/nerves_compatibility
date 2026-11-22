-module('Elixir.Mix.Tasks.Ncc.TraceCompile').
%% `mix ncc.trace_compile`: the worker's traced judge compile (precompiled
%% portability spec, R1). Starts ncc_tracer, then recompiles the closure of
%% NCC_TRACE_PACKAGE one dependency at a time with
%% Mix.Tasks.Deps.Compile.compile_single/3, each inside a window the task
%% opens and closes itself, with the sentinel fired inside it. In host mode
%% (`NCC_TRACE_MODE=host`) this is the run's host compile: after the closure
%% it runs Mix's `compile` for the project, so its exit status is the build's.
%% Written in Erlang so the worker app needs no :mix dependency; Mix finds it
%% by name.
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

%% The exit status of a trace whose sweep at a window boundary left processes
%% running or could not run (NccWorker.Tracer's `window_sweep_failed`).
-define(SWEEP_EXIT, 87).

%% Mix reads module.__info__(:attributes) for @shortdoc, @recursive and
%% @requirements; this task has none of them.
'__info__'(_Kind) -> [].

run(_Args) ->
    Input = driver_input(),
    ok = set_argv(Input),
    Packages = names("NCC_TRACE_PACKAGE"),
    First = names("NCC_TRACE_FIRST"),
    Native = names("NCC_TRACE_NATIVE"),
    Holders = holders("NCC_TRACE_HOLDERS"),
    case ncc_tracer:start_main() of
        {ok, Token} ->
            _ = ncc_tracer:holders(Token, Holders),
            traced(Token, {First, Packages}, Native, mode(), maps:get(late_env, Input, []));
        {error, _Why} -> erlang:exit({shutdown, 1})
    end.

%% What a firmware target's trace asks for beyond its env (NccWorker.Tracer's
%% driver.etf in NCC_TRACE_DIR), read before the tracer starts: `argv`, what
%% System.argv/0 returns to the compile, and `late_env`, put in the env only
%% once every dependency's mix.exs is evaluated (compile/4). No file is
%% nothing asked; any other failure to read it fails the trace.
driver_input() ->
    case os:getenv("NCC_TRACE_DIR") of
        false -> #{};
        Dir ->
            case file:read_file(filename:join(Dir, "driver.etf")) of
                {ok, Bin} -> input(binary_to_term(Bin, [safe]));
                {error, enoent} -> #{};
                {error, _Why} -> erlang:exit({shutdown, 1})
            end
    end.

input(#{argv := Argv, late_env := Late} = Input) when is_list(Late) ->
    true = Argv =:= nil orelse lists:all(fun erlang:is_binary/1, Argv),
    true = lists:all(fun({N, V}) -> is_binary(N) andalso is_binary(V) end, Late),
    Input;
input(_Other) -> erlang:exit({shutdown, 1}).

%% Under `mix firmware` System.argv/0 is ["firmware"]; here it would be
%% ["ncc.trace_compile"].
set_argv(#{argv := Argv}) when is_list(Argv) -> 'Elixir.System':argv(Argv);
set_argv(_Input) -> ok.

%% Nerves's own env: under `mix firmware`, nerves_bootstrap.init loads every
%% dependency (evaluating its mix.exs) before nerves.init exports it, and the
%% compile that follows, its own loading of the dependencies included
%% (load_deps/1), sees it. A write from this module's frame is the
%% toolchain's, never an event of the trace.
late_env(Pairs) ->
    lists:foreach(fun({N, V}) ->
                          true = os:putenv(unicode:characters_to_list(N),
                                           unicode:characters_to_list(V))
                  end, Pairs).

%% judge: recompile the closure only (a full run's dedicated judge compile).
%% host: the run's own host compile: the closure as in judge mode, then
%% Mix's compile of the project, so the exit status is the build's.
mode() ->
    case os:getenv("NCC_TRACE_MODE") of
        "host" -> host;
        _ -> judge
    end.

traced(Token, {First, Packages}, Native, Mode, Late) ->
    %% First, before Mix.Dep.load_and_cache/0 evaluates any dependency's
    %% mix.exs and before anything compiles: no package code has run in this
    %% VM yet, so the env is the one the project's config left (spec R5,
    %% ncc_tracer_config). The report refuses a trace without it, with two,
    %% or with one written after the closure line.
    _ = ncc_tracer:config_env(Token, ncc_tracer_config:snapshot()),
    Config = 'Elixir.Mix.Project':config(),
    Closure = with_build_lock(Config, fun() -> compile(Token, {First, Packages}, Native, Late) end),
    case project(Mode, Closure) of
        ok ->
            _ = consolidated(Token, Mode, Config),
            _ = ncc_tracer:finish(Token, ok),
            ok;
        {sweep_failed, App} ->
            _ = ncc_tracer:finish(Token, window_sweep_failed),
            io:format(standard_error,
                      "ncc.trace_compile: processes left running in ~ts's window could not be "
                      "stopped~n", [App]),
            erlang:exit({shutdown, ?SWEEP_EXIT});
        {not_in_closure, Missing} ->
            _ = ncc_tracer:finish(Token, package_not_in_closure),
            io:format(standard_error, "ncc.trace_compile: not in the project's dependencies: ~ts~n",
                      [lists:join(", ", [atom_to_list(M) || M <- Missing])]),
            erlang:exit({shutdown, 1});
        {failed, Class, Reason, Stack} ->
            _ = ncc_tracer:finish(Token, compile_failed),
            erlang:raise(Class, Reason, Stack)
    end.

%% After the build lock is released: Mix's compile takes it again. Every
%% closure dependency is compiled by now, so this compiles the project's own
%% app (and anything outside the package's closure, whose events fall outside
%% every window and count against everything). `--return-errors` makes a
%% failed compile return `{error, _}` rather than exit.
project(host, ok) -> project_compile();
project(_Mode, Result) -> Result.

project_compile() ->
    try 'Elixir.Mix.Task':run(<<"compile">>, [<<"--return-errors">>]) of
        {error, _Diagnostics} -> {failed, exit, {shutdown, 1}, []};
        _ -> ok
    catch
        Class:Reason:Stack -> {failed, Class, Reason, Stack}
    end.

%% The project compile ends with Mix's protocol consolidation, which loads
%% every consolidated protocol again from the project's consolidated dir,
%% without the patterns a natively built dependency's protocol had: the
%% tracer is told the dir, so its final sentinel can tell that reload from
%% any other (ncc_tracer:consolidated/2). If the dir cannot be had, nothing
%% is named and such a reload fails the check, as before.
consolidated(Token, host, Config) ->
    try 'Elixir.Mix.Project':consolidation_path(Config) of
        Dir when is_binary(Dir) -> ncc_tracer:consolidated(Token, Dir);
        _ -> skip
    catch
        _:_ -> skip
    end;
consolidated(_Token, _Mode, _Config) -> skip.

%% Unlike `mix deps.compile`, no `deps.precompile`: it is a hook, a no-op in a
%% plain project, and in a full run's Nerves project nerves_bootstrap aliases
%% it to work that would run package code outside every window.
compile(Token, {First, Packages}, Native, Late) ->
    try
        Deps = load_deps(Late),
        case {resolve_first(First, Deps), resolve(Packages, Deps)} of
            {{ok, FirstApps}, {ok, Apps}} -> compile_closure(Token, {FirstApps, Apps}, Deps, Native);
            {{error, Missing}, _} -> {not_in_closure, Missing};
            {_, {error, Missing}} -> {not_in_closure, Missing}
        end
    catch
        Class:Reason:Stack -> {failed, Class, Reason, Stack}
    end.

%% `NCC_TRACE_FIRST` (S9, a guarded-module proof build,
%% NccWorker.Portability.Guarded): packages whose closure compiles before
%% the packages' own, in a project where they are no dependency of those.
%% None is the usual: nothing first.
resolve_first([], _Deps) -> {ok, []};
resolve_first(Names, Deps) -> resolve(Names, Deps).

compile_closure(Token, {FirstApps, Apps}, Deps, Native) ->
    First = closure_order(FirstApps, Deps),
    Ordered = First ++ [D || D <- closure_order(Apps, Deps), not lists:member(D, First)],
    _ = ncc_tracer:closure(Token, Apps, [dep_info(D) || D <- Ordered]),
    DepConfig = 'Elixir.Mix.Project':deps_config(),
    compile_deps(Token, Ordered, Native, DepConfig).

%% One window at a time; a window whose sweep failed ends the compile.
compile_deps(_Token, [], _Native, _DepConfig) -> ok;
compile_deps(Token, [Dep | Rest], Native, DepConfig) ->
    case compile_dep(Token, Dep, Native, DepConfig) of
        ok -> compile_deps(Token, Rest, Native, DepConfig);
        {sweep_failed, _App} = Failed -> Failed
    end.

%% The dependencies as the compile loads them. With a late env (a firmware
%% target's trace) they are loaded twice, as `mix firmware` loads them:
%% once by nerves_bootstrap.init's deps.loadpaths before Nerves exports its
%% env, and again by the compile's own deps.loadpaths after it
%% (Mix.Dep.load_and_cache/0 converges anew at the top each time). Each
%% mix.exs is evaluated once, at the first load, so its module attributes
%% see the env unset; what the dependencies are compiled with comes from
%% the second, with the env set: a Mix dependency's `deps:` (its
%% project/0, called again) and a rebar3 dependency's rebar.config.script
%% (evaluated again, and written out as the mix.rebar.config rebar3 reads).
load_deps([]) -> 'Elixir.Mix.Dep':load_and_cache();
load_deps(Late) ->
    _ = 'Elixir.Mix.Dep':load_and_cache(),
    ok = late_env(Late),
    'Elixir.Mix.Dep':load_and_cache().

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

%% Before the window closes, the collector kills whatever the compile left
%% running (ncc_tracer:sweep/2): a native build's make, cmake or cargo is not
%% traced, and a process it leaves behind must not live on into a later
%% window, nor change the build its close digests.
compile_dep(Token, Dep, Native, DepConfig) ->
    App = maps:get(app, Dep),
    _ = ncc_tracer:window_open(Token, App),
    _ = ncc_tracer:fire(App),
    _ = 'Elixir.Mix.Tasks.Deps.Compile':compile_single(Dep, true, DepConfig),
    case swept(ncc_tracer:sweep(Token, App)) of
        true -> close_window(Token, App, Dep, Native);
        false -> {sweep_failed, App}
    end.

%% A collector that is gone (killed, or past its heap cap) has already cost
%% the trace its judgement, which its report says: the compile goes on, so
%% the host status stays the package's own. Any other answer but ok, a
%% failed sweep or a collector that did not answer in time, ends it.
swept(ok) -> true;
swept({error, no_tracer}) -> true;
swept(_Other) -> false.

close_window(Token, App, Dep, Native) ->
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

%% `app:Module,app:Module`, read before any package code runs: a relocation's
%% second build names the modules whose calls its later windows record
%% (ncc_tracer:holders/2).
holders(Var) ->
    [begin
         [App, Mod] = string:split(Pair, ":"),
         {list_to_atom(App), list_to_atom(Mod)}
     end || Pair <- string:lexemes(os:getenv(Var, ""), ",")].
