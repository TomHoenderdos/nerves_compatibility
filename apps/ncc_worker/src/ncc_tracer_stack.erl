-module(ncc_tracer_stack).
%% Stage-1 classification of one traced call by the stack it was made from
%% (precompiled portability spec, R1 steps 1-3). The tracer passes in which
%% modules are toolchain and whether the calling process is a user process.
-export([extent/4, extent/5, frame/1, mfa_bin/3, dispatcher/1, dispatchers/0, first_kind/2,
         uncached/0, printers/0, diagnosers/0, checker/2, made_by_toolchain/2,
         made_by_mix/2, made_by_mix_strict/2, target_read_by_mix/2, compiler_frame/1]).

-define(WRAPPERS, [os, 'Elixir.System', 'Elixir.Application', application, 'Elixir.File']).
%% Frames a call is attributed through, to the frame that called them, when
%% the first frame is picked: IO.ANSI and Logger.Formatter read
%% `:elixir, :ansi_enabled` for their caller, and only the caller decides
%% whether the answer reaches code (a module attribute holding
%% IO.ANSI.format/1's or Logger.Formatter.format/2's result) or only output
%% (Mix's shell, Logger's handler). Such a frame is skipped only when it is
%% the toolchain's own module: a package's module of the same name stays
%% the first frame. Skipping changes which frame is first, never how a
%% frame is classified: every frame keeps its own module's kind, the
%% user-frame search sees the whole stack, and a stack of nothing else has
%% no first frame (the package's own read).
-define(ATTRIBUTED_THROUGH, ['Elixir.IO.ANSI', 'Elixir.Logger.Formatter']).
%% Modules whose kind decides a skip above or a reviewed drop of a config
%% read (`NccWorker.Portability.ConfigReads`, keyed on the first frame): the
%% tracer classifies them afresh on every event, never from its per-module
%% cache, so a package that redefines one mid-compile is not taken for the
%% toolchain's.
-define(UNCACHED, ?ATTRIBUTED_THROUGH ++ ['Elixir.Mix.Shell.IO', logger_h_common, elixir_errors,
                                          'Elixir.Module.Types.Apply']).
%% The compiler's diagnostics module colours a warning or error by
%% `:elixir, :ansi_enabled` while formatting it. Its frame stays first only
%% when one of its printing functions (the ones that format a diagnostic and
%% write it to standard error) is below it with nothing else in between.
%% Reached any other way (`SyntaxError.message/1` formats a snippet and
%% returns the coloured text to its caller) its frames are skipped like the
%% ones above, so the read belongs to whoever asked for the text.
-define(PRINTED_BY, [{elixir_errors, ["print_diagnostic", "print_diagnostics", "print_warning"]}]).
%% The type checker colours the offending part of a bad call by
%% `:elixir, :ansi_enabled` (Module.Types.Apply's ansi_red/1) while it
%% formats a warning. Its frame stays first only on the way down to the
%% checker's grouping of diagnostics (group_diagnostics/1 on 1.20,
%% group_warnings/1 on 1.19), which hands them to the function that prints
%% and returns them: between the two only Apply's own frames and toolchain
%% folds (the toolchain's Enum and lists), and the first checker frame
%% below them one of the grouping function's own. Reached any other way,
%% Apply's frames are skipped like IO.ANSI's, so the read belongs to whoever
%% asked for the text. Where the diagnostics go from there is the config
%% read judge's business: a window in which package code compiled or
%% captured diagnostics itself does not get the drop.
-define(DIAGNOSED_BY, [{'Elixir.Module.Types.Apply', "ansi_red", 'Elixir.Module.ParallelChecker',
                        ["group_diagnostics", "group_warnings"]}]).
%% A frame a read is attributed to only when the skipped frame right above
%% it is the toolchain's module it is paired with: Logger's handler calls
%% the formatter, and a package's formatter that tail-calls IO.ANSI leaves
%% no frame of its own, so the IO.ANSI frame stays first instead.
-define(REACHED_THROUGH, [{logger_h_common, 'Elixir.Logger.Formatter'}]).
%% The frames left on top when package code tail-calls a primitive from a
%% compile-time hook. Pinned per toolchain by the fixture suite.
-define(DISPATCHERS, [{elixir_module, "expand_callback"}, {elixir_module, "eval_callbacks"},
                      {elixir_dispatch, "expand_macro_fun"},
                      {elixir_def, "run_on_definition_callbacks"},
                      {compile, "foldl_transform"}, {compile, "foldl_core_transforms"},
                      {'Elixir.Mix.Task', "run_task"},
                      {'Elixir.Module.ParallelChecker', "verify"},
                      {'Elixir.Kernel.ParallelCompiler', "verify_modules"}]).
%% Toolchain higher-order and eval frames: package code that tail-calls
%% through them (`Enum.map(vars, &System.get_env/1)` in a macro,
%% `Code.eval_string` in a callback) leaves only these between the call and
%% the dispatcher that ran it. Of `Code` only the eval functions are glue:
%% `Code.compile_file/2` reading a mix.exs runs under
%% `Module.ParallelChecker.verify/1` on every project load.
%% Non-tail higher-order functions count too (`Map.update(m, k, d,
%% &System.get_env/1)` leaves `Map.update/4` on the stack), and so do the
%% protocol implementations Enum and Stream go through (matched by prefix).
-define(GLUE, ['Elixir.Enum', 'Elixir.Stream', 'Elixir.Map', 'Elixir.Keyword', 'Elixir.List',
               'Elixir.MapSet', 'Elixir.Access', 'Elixir.Enumerable', 'Elixir.Collectable',
               lists, maps, proplists, sets, ordsets, gb_trees, gb_sets, orddict, dict,
               array, digraph, erl_eval, elixir, elixir_eval]).
-define(GLUE_PREFIXES, ["Elixir.Enumerable.", "Elixir.Collectable."]).
%% The Mix functions that read the target (Mix.target/0, so Mix.State.get/2
%% and its ets:lookup/2) for Mix's own work: every call site in Mix 1.19 and
%% 1.20, by enclosing function. Mix.State's own get/fetch make the lookup
%% under Mix.target/0 or a direct call, which is judged at that call.
-define(MIX_TARGET_READERS, [{'Elixir.Mix.State', "get"}, {'Elixir.Mix.State', "fetch"},
                             {'Elixir.Mix.Tasks.Compile.App', "matching_target?"},
                             {'Elixir.Mix.Tasks.Deps', "run"},
                             {'Elixir.Mix.Tasks.Escript.Build', "gen_main"},
                             {'Elixir.Mix.Tasks.Escript.Build', "main_body_for"},
                             {'Elixir.Mix.Tasks.Release', "build_rel"},
                             {'Elixir.Mix.Tasks.Release', "maybe_add_config_reader_provider"},
                             {'Elixir.Mix.Tasks.Loadconfig', "load_compile"},
                             {'Elixir.Mix.Tasks.Loadconfig', "load_runtime"},
                             {'Elixir.Mix.Tasks.Deps.Partition', "server"},
                             {'Elixir.Mix.Dep', "cached"},
                             {'Elixir.Mix.Dep', "load_and_cache"},
                             {'Elixir.Mix.Config', "eval!"},
                             {'Elixir.Mix.Config', "read!"},
                             {'Elixir.Mix.Project', "push_config"},
                             {'Elixir.Mix.Project', "build_target"},
                             {'Elixir.Mix.CLI', "maybe_change_env_and_target"}]).
%% Mix functions that run a fun they were given: a package fun that
%% tail-called a read leaves one of these on top.
-define(MIX_FUN_HELPERS, [{'Elixir.Mix.ProjectStack', "recur"},
                          {'Elixir.Mix.ProjectStack', "on_clean_slate"},
                          {'Elixir.Mix.ProjectStack', "handle_call"},
                          {'Elixir.Mix.Project', "in_project"},
                          {'Elixir.Mix.Project', "with_build_lock"},
                          {'Elixir.Mix.Project', "with_deps_lock"},
                          {'Elixir.Mix.Project', "traverse_deps_depth"},
                          {'Elixir.Mix.Project', "traverse_deps_map"},
                          {'Elixir.Mix.Sync.Lock', "with_lock"},
                          {'Elixir.Mix.Dep', "in_dependency"},
                          {'Elixir.Mix.Dep.Loader', "with_system_env"},
                          {'Elixir.Mix.State', "update"},
                          {'Elixir.Mix.Tasks.Loadconfig', "preserve_config"},
                          {'Elixir.Mix', "in_install_project"}]).

extent(Stack, Depth, IsToolchain, ProcessIsUser) ->
    extent(Stack, Depth, IsToolchain, ProcessIsUser, fun(_File) -> false end).

%% IsScript(File) is true for the source file of the running mix script
%% (`elixir -S mix` evaluates bin/mix as elixir_compiler_0, which has no
%% object file); the tracer passes it only for the driver process. Only the
%% bottom-most elixir_compiler_N frame of the stack can be the script (below
%% it there is only Kernel.CLI loading it): a frame of that file anywhere
%% else (Code.compile_string(Src, <bin/mix>) from package code puts one above
%% the real one) is judged as in extent/4. The script frame is toolchain and
%% no module body.
extent([], _Depth, _IsToolchain, _ProcessIsUser, _IsScript) ->
    %% No frame at all (a spawned fun that tail-called the primitive): fail closed.
    {user, truncated, none, none};
extent(Stack0, Depth, IsToolchain, ProcessIsUser, IsScript) ->
    Stack = mark_script(Stack0, IsScript),
    Stripped = strip(Stack, IsToolchain),
    First = case Stripped of
                [Frame | _] -> Frame;
                [] -> none
            end,
    case lists:search(fun({M, _, _, _} = F) -> not (IsToolchain(M) orelse script(F)) end, Stack) of
        {value, User} -> {user, frame, First, User};
        false -> no_user_frame(Stack, Stripped, Depth, First, ProcessIsUser)
    end.

no_user_frame(Stack, Stripped, Depth, First, ProcessIsUser) ->
    case {dispatched(Stack, Stripped), length(Stack) >= Depth, ProcessIsUser} of
        {true, _, _} -> {user, dispatcher, First, none};
        {false, true, _} -> {user, truncated, First, none};
        {false, false, true} -> {user, lineage, First, none};
        {false, false, false} -> toolchain
    end.

%% A dispatcher reached from the top through glue frames only (the
%% tail-call signature, the first frame after the wrappers being the
%% shortest case), or eval frames with a dispatcher or a module body below.
dispatched(Stack, Stripped) ->
    glue_to_dispatcher(Stripped) orelse eval_under_dispatcher(Stack).

glue_to_dispatcher([Frame | Rest]) ->
    case dispatcher(Frame) of
        true -> true;
        false -> glue(Frame) andalso glue_to_dispatcher(Rest)
    end;
glue_to_dispatcher([]) -> false.

glue({'Elixir.Code', F, _, _}) ->
    lists:prefix("eval", base_name(F)) orelse lists:prefix("validated_eval", base_name(F));
glue({M, F, _, _}) ->
    lists:member(M, ?GLUE) orelse lists:member(M, ?WRAPPERS) orelse eval_handler(F)
        orelse protocol_impl(M).

protocol_impl(M) ->
    Name = atom_to_list(M),
    lists:any(fun(Prefix) -> lists:prefix(Prefix, Name) end, ?GLUE_PREFIXES).

eval_under_dispatcher([Frame | Rest]) ->
    case eval(Frame) of
        true -> lists:any(fun(Below) -> dispatcher(Below) orelse module_body(Below) end, Rest);
        false -> eval_under_dispatcher(Rest)
    end;
eval_under_dispatcher([]) -> false.

eval({M, F, _, _}) -> M =:= erl_eval orelse eval_handler(F).

eval_handler(F) -> F =:= eval_external_handler.

%% elixir_compiler_N: a module body or file being evaluated, but not the
%% running mix script.
module_body(Frame) -> compiler_frame(Frame) andalso not script(Frame).

%% The script frame carries a marker mark_script/2 adds to its location; a
%% traced stack never has that key.
script({_, _, _, Location} = Frame) ->
    compiler_frame(Frame) andalso is_list(Location)
        andalso lists:keymember(ncc_tracer_mix_script, 1, Location).

mark_script(Stack, IsScript) ->
    {Below, Rest} = lists:splitwith(fun(F) -> not compiler_frame(F) end, lists:reverse(Stack)),
    case Rest of
        [{M, F, A, Location} = Frame | Above] when is_list(Location) ->
            case script_file(Frame, IsScript) of
                true ->
                    Marked = {M, F, A, Location ++ [{ncc_tracer_mix_script, true}]},
                    lists:reverse(Below ++ [Marked | Above]);
                false -> Stack
            end;
        _ -> Stack
    end.

script_file({_, _, _, Location}, IsScript) ->
    case lists:keyfind(file, 1, Location) of
        {file, File} -> IsScript(ncc_tracer_channels:chars(File)) =:= true;
        false -> false
    end.

compiler_frame({M, _, _, _}) ->
    case atom_to_list(M) of
        "elixir_compiler_" ++ [D | Ds] -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, [D | Ds]);
        _ -> false
    end.

strip(Stack, IsToolchain) -> strip(Stack, none, IsToolchain).

strip([{M, _, _, _} = Frame | Rest] = Stack, Above, IsToolchain) ->
    Skip = lists:member(M, ?WRAPPERS)
        orelse (lists:member(M, ?ATTRIBUTED_THROUGH) andalso IsToolchain(M))
        orelse unprinted(M, Stack, IsToolchain)
        orelse undiagnosed(M, Stack, IsToolchain),
    case Skip of
        true -> strip(Rest, Frame, IsToolchain);
        false -> reached(Stack, Above)
    end;
strip([], _Above, _IsToolchain) -> [].

reached([{M, _, _, _} | _] = Stack, {AboveM, _, _, _} = Above) ->
    Through = lists:member(AboveM, ?ATTRIBUTED_THROUGH),
    case lists:keyfind(M, 1, ?REACHED_THROUGH) of
        {M, Via} when Through, AboveM =/= Via -> [Above | Stack];
        _ -> Stack
    end;
reached(Stack, none) -> Stack.

%% A frame of a PRINTED_BY module not on an unbroken run down to one of its
%% printing functions: only frames of the module itself and the toolchain's
%% ATTRIBUTED_THROUGH frames may lie between. Any other frame (a package's
%% Inspect implementation a printer reached while formatting a stacktrace
%% entry, say) asked for the text itself, so the read is its own. A
%% redefined module (not the toolchain's) is never skipped.
unprinted(M, Stack, IsToolchain) ->
    case lists:keyfind(M, 1, ?PRINTED_BY) of
        {M, Printers} -> IsToolchain(M) andalso not printed_run(Stack, M, Printers, IsToolchain);
        false -> false
    end.

printed_run([{M, F, _, _} | Rest], M, Printers, IsToolchain) ->
    lists:member(base_name(F), Printers) orelse printed_run(Rest, M, Printers, IsToolchain);
printed_run([{A, _, _, _} | Rest], M, Printers, IsToolchain) ->
    lists:member(A, ?ATTRIBUTED_THROUGH) andalso IsToolchain(A)
        andalso printed_run(Rest, M, Printers, IsToolchain);
printed_run([], _M, _Printers, _IsToolchain) -> false.

%% A frame of a DIAGNOSED_BY module is skipped unless it is the reading
%% function on an unbroken run down to a grouping function. A redefined
%% module (not the toolchain's) is never skipped.
undiagnosed(M, [{M, F, _, _} | Below], IsToolchain) ->
    case lists:keyfind(M, 1, ?DIAGNOSED_BY) of
        {M, Reader, Checker, Groupers} ->
            IsToolchain(M) andalso
                not (base_name(F) =:= Reader
                     andalso grouped_run(Below, M, Checker, Groupers, IsToolchain));
        false -> false
    end;
undiagnosed(_M, _Stack, _IsToolchain) -> false.

%% Down from the reader: frames of the module itself and the toolchain's
%% Enum and lists (the folds and maps both use), then a frame of the
%% grouping function (its body or a fun in it). Any other frame, a checker
%% frame of another function or an eval frame among them, ends the run.
-define(FOLDS, ['Elixir.Enum', lists]).
grouped_run([{M, _, _, _} | Rest], M, Checker, Groupers, IsToolchain) ->
    grouped_run(Rest, M, Checker, Groupers, IsToolchain);
grouped_run([{Checker, F, _, _} | _], _M, Checker, Groupers, IsToolchain) ->
    IsToolchain(Checker) andalso lists:member(base_name(F), Groupers);
grouped_run([{A, _, _, _} | Rest], M, Checker, Groupers, IsToolchain) ->
    lists:member(A, ?FOLDS) andalso IsToolchain(A)
        andalso grouped_run(Rest, M, Checker, Groupers, IsToolchain);
grouped_run([], _M, _Checker, _Groupers, _IsToolchain) -> false.

%% The toolchain frames a lookup is made through on its way from the type
%% checker: the code server's loading functions and the error handlers.
-define(LOOKUP_THROUGH, [code, error_handler, 'Elixir.Kernel.ErrorHandler', 'Elixir.Code']).

%% Whether the first frame past the wrappers and LOOKUP_THROUGH is Elixir's
%% type checker (Module.ParallelChecker, a Module.Types module), each frame
%% checked against the toolchain. Frames below it may be cut off: the
%% checker's stacks are deep.
checker(Stack, IsToolchain) when is_list(Stack) ->
    Through = fun({M, _, _, _}) ->
                      lists:member(M, ?WRAPPERS)
                          orelse (lists:member(M, ?LOOKUP_THROUGH) andalso IsToolchain(M))
              end,
    case lists:dropwhile(Through, Stack) of
        [{M, _, _, _} | _] -> checker_module(M) andalso IsToolchain(M);
        [] -> false
    end;
checker(_Stack, _IsToolchain) -> false.

%% The dispatchers that run code of the toolchain's own: the checker and
%% the parallel compiler. Every other one runs package code (a hook, a
%% macro, a transform).
-define(TOOLCHAIN_DISPATCHERS, [{'Elixir.Module.ParallelChecker', "verify"},
                                {'Elixir.Kernel.ParallelCompiler', "verify_modules"}]).

%% Whether the compiler made a call, judged by the first frame past the
%% wrappers and the toolchain's glue (Enum and friends): one of the
%% compiler's own modules (compiler_module/1), the toolchain's, that is not a
%% dispatcher of package code. Any other toolchain frame on top (Task's, a
%% GenServer's) may be running a fun package code handed it, which
%% tail-called the checker: that is the package's call. So is a hook
%% dispatcher on top, and a stack with no frame left (false).
made_by_toolchain(Stack, IsToolchain) when is_list(Stack) ->
    Skip = fun({M, _, _, _} = F) ->
                   lists:member(M, ?WRAPPERS)
                       orelse (IsToolchain(M) andalso glue(F) andalso not dispatcher(F))
           end,
    case lists:dropwhile(Skip, Stack) of
        [{M, F, _, _} = Frame | _] ->
            compiler_module(M) andalso IsToolchain(M) andalso
                (not dispatcher(Frame)
                 orelse lists:member({M, base_name(F)}, ?TOOLCHAIN_DISPATCHERS));
        [] -> false
    end;
made_by_toolchain(_Stack, _IsToolchain) -> false.

%% Whether Mix made a call into one of its compile entry points
%% (ncc_tracer_channels mix_entry/1): the first frame past the wrappers, the
%% toolchain's higher-order glue (not its eval functions: evaluated code is
%% not Mix's, whoever evaluates it) and Mix.Task.Compiler's after_compiler/2
%% is one of Mix's own modules, the toolchain's. Mix.Task's task runner on
%% top counts as Mix's: it runs every task, and a package task that
%% tail-called the entry point left no frame to take the result.
made_by_mix(Stack, IsToolchain) -> made_by_mix(Stack, IsToolchain, true).

%% The same for a build path read (ncc_tracer_channels mix_state/3), except
%% that a dispatcher (Mix.Task's task runner) or one of Mix's fun-calling
%% helpers (?MIX_FUN_HELPERS) on top is the package's call: a package fun
%% or task run/1 that tail-called the read returns its value to package
%% code. Only observations depend on it; target reads use the allow-list
%% (target_read_by_mix/2).
made_by_mix_strict(Stack, IsToolchain) -> made_by_mix(Stack, IsToolchain, false).

%% Whether one of the Mix functions that read the target for Mix's own work
%% (?MIX_TARGET_READERS, every Mix.target() call site in Mix 1.19 and 1.20)
%% made a target read: the first frame past the wrappers and the toolchain's
%% higher-order glue. Anything else (a package fun Mix.ProjectStack.recur/1
%% or Mix.Project.in_project/4 ran, a package task, any Mix function this
%% list does not name) is the package's read: fail closed.
target_read_by_mix(Stack, IsToolchain) when is_list(Stack) ->
    case lists:dropwhile(fun(Frame) -> mix_skip(Frame, IsToolchain) end, Stack) of
        [{M, F, _, _} | _] ->
            IsToolchain(M) andalso lists:member({M, base_name(F)}, ?MIX_TARGET_READERS);
        [] -> false
    end;
target_read_by_mix(_Stack, _IsToolchain) -> false.

made_by_mix(Stack, IsToolchain, DispatcherIsMix) when is_list(Stack) ->
    case lists:dropwhile(fun(Frame) -> mix_skip(Frame, IsToolchain) end, Stack) of
        [{M, F, _, _} = Frame | _] ->
            (DispatcherIsMix orelse
             not (dispatcher(Frame) orelse lists:member({M, base_name(F)}, ?MIX_FUN_HELPERS)))
                andalso IsToolchain(M) andalso lists:prefix("Elixir.Mix.", atom_to_list(M));
        [] -> false
    end;
made_by_mix(_Stack, _IsToolchain, _DispatcherIsMix) -> false.

mix_skip({M, F, _, _} = Frame, IsToolchain) ->
    lists:member(M, ?WRAPPERS)
        orelse (IsToolchain(M) andalso
                ((glue(Frame) andalso not eval_glue(Frame) andalso not dispatcher(Frame))
                 orelse (M =:= 'Elixir.Mix.Task.Compiler'
                         andalso base_name(F) =:= "after_compiler"))).

eval_glue({M, _, _, _} = Frame) ->
    M =:= 'Elixir.Code' orelse M =:= elixir orelse M =:= elixir_eval orelse eval(Frame).

%% The compiler's own call graph into the checker and the compile entry
%% points: Elixir's compiler (elixir_*), Code, Module, the parallel compiler
%% and checker, the type checker, the error handlers and Mix's compilers.
-define(COMPILER, ['Elixir.Code', 'Elixir.Module', 'Elixir.Kernel.ParallelCompiler',
                   'Elixir.Module.ParallelChecker', 'Elixir.Module.Types', 'Elixir.Kernel.ErrorHandler',
                   error_handler, code]).
-define(COMPILER_PREFIXES, ["elixir_", "Elixir.Module.Types.", "Elixir.Mix.Compilers.",
                            "Elixir.Mix.Tasks.Compile."]).

compiler_module(M) -> lists:member(M, ?COMPILER) orelse compiler_prefix(atom_to_list(M)).

%% elixir_compiler_N is a module body or eval'd code, never the compiler.
compiler_prefix("elixir_compiler_" ++ _) -> false;
compiler_prefix(Name) -> lists:any(fun(P) -> lists:prefix(P, Name) end, ?COMPILER_PREFIXES).

checker_module('Elixir.Module.ParallelChecker') -> true;
checker_module('Elixir.Module.Types') -> true;
checker_module(M) -> lists:prefix("Elixir.Module.Types.", atom_to_list(M)).

uncached() -> ?UNCACHED.

printers() -> [{M, [list_to_atom(F) || F <- Fs]} || {M, Fs} <- ?PRINTED_BY].

diagnosers() ->
    [{M, list_to_atom(R), C, [list_to_atom(G) || G <- Gs]} || {M, R, C, Gs} <- ?DIAGNOSED_BY].

dispatcher({M, F, _, _}) -> lists:member({M, base_name(F)}, ?DISPATCHERS).

dispatchers() -> [{M, list_to_atom(F)} || {M, F} <- ?DISPATCHERS].

%% Whose code made a call, judged by the first frame after the wrappers
%% (precompiled portability spec, R5): the toolchain's own code (`toolchain`:
%% Logger's macros, IO.warn), a frame package code reaches the call through
%% (`glue`: the higher-order and eval functions and the dispatchers that a
%% tail call leaves on top), anything else (`user`), or no frame (`none`).
first_kind({M, _F, _A, _Location} = Frame, IsToolchain) ->
    case dispatcher(Frame) orelse glue(Frame) of
        true -> <<"glue">>;
        false -> toolchain_kind(IsToolchain(M))
    end;
first_kind(_NoFrame, _IsToolchain) -> <<"none">>.

toolchain_kind(true) -> <<"toolchain">>;
toolchain_kind(false) -> <<"user">>.

%% "-expand_callback/6-fun-0-" -> "expand_callback"
base_name(F) ->
    case atom_to_list(F) of
        [$- | Rest] -> lists:takewhile(fun(C) -> C =/= $/ end, Rest);
        Name -> Name
    end.

frame(none) -> null;
frame({M, F, A, Location}) ->
    #{module => atom_to_binary(M), function => atom_to_binary(F), arity => arity(A),
      file => file(Location), line => line(Location)}.

arity(A) when is_integer(A) -> A;
arity(Args) when is_list(Args) -> length(Args).

file(Location) ->
    case lists:keyfind(file, 1, Location) of
        {file, File} -> ncc_tracer_channels:chars(File);
        false -> null
    end.

line(Location) ->
    case lists:keyfind(line, 1, Location) of
        {line, Line} when is_integer(Line) -> Line;
        _ -> null
    end.

mfa_bin(M, F, A) ->
    {Name, Separator} = case atom_to_binary(M) of
                            <<"Elixir.", Rest/binary>> -> {Rest, <<".">>};
                            Plain -> {Plain, <<":">>}
                        end,
    iolist_to_binary([Name, Separator, atom_to_binary(F), "/", integer_to_binary(A)]).
