-module(ncc_tracer).
%% Compile-time observation trace (precompiled portability spec, R1). Runs in
%% the VM that compiles the package: start_main/0 from `mix ncc.trace_compile`,
%% start_child/0 from ERL_AFLAGS in every other BEAM the compile starts
%% (rebar3). Writes one JSON object per line; NccWorker.Tracer.Report reads them.
-export([start_main/0, start_child/0, window_open/2, window_close/2, closure/3, built/3,
         config_env/2, sweep/2,
         native_patterns/3, holders/2, consolidated/2, finish/2, fire/1, ebin_dir/0, flush/0,
         collector/0]).
%% Exported for the tests: stage-1 classification that never crashes.
-export([safe_extent/4, maps_libs/1, built_fields/2, loaded_by_mix/0, object_verdict/4,
         installed_app/3, cache_hit/2, canary_patterns/0, code_prepared/3, code_finished/2,
         prepared_ref/2, on_load_ran/2, toolchain_code/2, installed_modules/2]).

-include_lib("kernel/include/file.hrl").

-define(DEPTH, 64).
-define(COLLECTOR, {?MODULE, collector}).
-define(PROBE, ncc_tracer_probe).
-define(DRIVER, 'Elixir.Mix.Tasks.Ncc.TraceCompile').
%% Modules Mix itself has loaded, with or without Hex, before it evaluates a
%% dependency's mix.exs or compiles anything, in every untraced compile: a
%% probe of one answers the same traced or not, so in the Mix VM they are
%% not `preloaded`. Pinned per toolchain by the host-mode fixture suite
%% (`loaded_by_mix/0`). Not in a child VM, which is rebar3, not Mix.
-define(LOADED_BY_MIX, [crypto, gen_tcp]).
%% Applications on the code path of every compile Mix makes of an Elixir
%% project's dependency, whatever it lists: Mix.AppLoader's extra
%% applications (ex_unit, iex, mix, elixir), what they list, and erts; and
%% logger, which Mix has loaded before any compile (as app_calls/1 and
%% NccWorker.Portability.Probes take it).
-define(ON_EVERY_PATH, [<<"kernel">>, <<"stdlib">>, <<"compiler">>, <<"erts">>, <<"elixir">>,
                        <<"mix">>, <<"iex">>, <<"ex_unit">>, <<"logger">>]).
-define(SENTINEL, "NCC_TRACE_SENTINEL:").
-define(TIMEOUT, 120000).
-define(WRITE_BUFFER, 262144).
%% The bytes of recorded values (value lines) one trace file may hold. Each
%% distinct value is written once; one past this is recorded `unrecordable`,
%% so values never overflow a trace nor outgrow the report's read budget.
-define(MAX_VALUE_BYTES, 8388608).
%% How far past twice what its last collection left the collector's heap
%% may grow before it collects again, once it has handled a message
%% (collected/1): 2^20 words, 8 MiB.
-define(GC_GROWTH, 1048576).
-define(INTROSPECTION, ['__info__', module_info, behaviour_info]).
%% A match spec that never matches: the pattern is set, no call is traced.
-define(NEVER, [{'_', [false], []}]).
%% Every load of Erlang code passes here (erlang:prepare_loading/2,
%% erlang:load_module/2, the code server, or a package calling it itself):
%% traced without a stack, tagged, for code_prepared/3, with its return (the
%% prepared code's reference) for code_finished/2.
-define(PREPARE_LOADING, {erts_internal, prepare_loading, 2}).
%% What makes prepared code current, in any process and at any later time
%% (code:finish_loading/1 too): traced without a stack, tagged, with its
%% return, which names the modules whose code has an on_load function to
%% run before it is made current (erlang:call_on_load_function/1, which no
%% pattern can trace).
-define(FINISH_LOADING, {erlang, finish_loading, 1}).
%% Prepared code references code_finished/2 waits on at once, either way
%% round; past that every check fails.
-define(MAX_REFS, 4096).
%% The most in-memory modules the end line lists (in_memory/0).
-define(MAX_IN_MEMORY, 4000).
%% The distinct versions of one module's code code_prepared/3 keeps; past
%% that the module's history is only `overflow`, which fails the check once
%% the module is ever taken for the toolchain's.
-define(MAX_PREPARED, 16).
-define(SPAWNS, [spawn, spawn_link, spawn_monitor, spawn_opt, spawn_request]).

%% set_depth: the backtrace_depth the tracer set and read back at start.
%% depth: the live depth as far as the collector knows it, lowered when a
%% traced erlang:system_flag(backtrace_depth, N) call says so; every stack is
%% judged against it. lowered: a lowering was seen since the last check.
%% sources: compile:file/2 calls awaiting their return (child mode).
%% spawning: processes whose spawn call was made in user extent, awaiting
%% the `spawn` trace message that names the child.
%% wanted: every pattern as {MFA, MatchSpec}, checked at each sentinel,
%% window close and finish; unpatterned: a sentinel found one missing.
%% final_pid, final_nonce: who may fire the final sentinel, and with what.
%% unloaded: modules the tracer's own code calls that could not be loaded at
%% start (load_uses/0); one loaded by the end is reported (`late_loaded`).
%% token: the secret start/3 hands the driver; every request but flush must
%% carry it. watcher, wref: the process that records the collector's death,
%% monitored in turn. tampered: a forged request or a dead watcher was seen;
%% it fails every check until the end.
%% consolidated: the project's protocol consolidation dir, named by the
%% driver after the project compile (host mode), else none.
%% sweep: {on, WorkerStart} when the worker asked the Mix VM to sweep the
%% container at each window boundary (NCC_TRACE_SWEEP, read at start, before
%% any package code runs), else off.
%% returns: per process, a stack of the return-traced calls awaiting their return ({call, CallId, Args} or skip).
%% values: each recorded value's ETF => its value_id; value_bytes: the bytes
%% of value lines written, at most max_value_bytes.
%% gc_at: the heap size, in words, past which collected/1 collects.
-record(st, {fd, file, session, initial = #{}, procs = #{}, native = #{}, holders = #{},
             holders_wanted = #{}, sources = #{},
             spawning = #{}, parents = #{}, set_depth = ?DEPTH, depth = ?DEPTH, lowered = false,
             wanted = [], unpatterned = false, final_pid, final_nonce, unloaded = [],
             token, watcher, wref, tampered = false, libs = unavailable, libs_written = false,
             calls = 0, user = 0, truncated = 0, unjudged = 0, spawned = 0, path_os_reads = 0,
             dropped_probes = 0, compact = false, ensured_seen = #{},
             max_calls, max_user, max_queue, overflow = false, final = false,
             returns = #{}, values = #{}, value_bytes = 0, max_value_bytes,
             consolidated = none, sweep = off, gc_at = ?GC_GROWTH}).

%% --- API used by the driver ---------------------------------------------

%% Both take the loaded modules first, before the tracer loads anything:
%% what it loads from here on is `preloaded` (preloaded/1).
start_main() ->
    Before = loaded(),
    Dir = os:getenv("NCC_TRACE_DIR"),
    case os:getenv("MIX_OS_DEPS_COMPILE_PARTITION_COUNT") of
        V when V =:= false; V =:= "" -> start(main, Dir, "main", Before);
        _ -> refuse_start(Dir, <<"partitions">>)
    end.

start_child() ->
    try
        Before = loaded(),
        case os:getenv("NCC_TRACE_DIR") of
            false -> ok;
            Dir ->
                App = child_app(),
                {ok, _Token} = start(child, Dir, App, Before),
                _ = fire(App),
                ok
        end
    catch
        _:_ -> ok
    end.

%% Token is what start_main/0 returned. The driver keeps it in its own
%% variables: not in the process dictionary, which compiled code can read
%% untraced, and not anywhere global. Reading another process's dictionary,
%% stack or mailbox goes through process_info, which is an integrity pattern.
window_open(Token, App) -> call(Token, {window_open, bin(App), now_ns()}).

window_close(Token, App) ->
    Delivered = delivered(),
    call(Token, {window_close, bin(App), now_ns(), Delivered =:= ok}).

closure(Token, Packages, Deps) -> call(Token, {closure, [bin(P) || P <- Packages], Deps}).

%% The digest of what App's compile left in its build dir (ncc_tracer_digest),
%% taken by the collector, which is not traced, right after its window.
built(Token, App, Dir) -> call(Token, {built, bin(App), Dir}).

%% Kills what App's compile left running (ncc_tracer_sweep), before its window
%% closes: ok, or an error when the worker asked for the sweep and something
%% survived it or it could not run. The collector does it, untraced, and
%% writes a sweep line; with no sweep asked for it does nothing.
sweep(Token, App) -> call(Token, {sweep, bin(App)}).

%% The driver's application-env snapshot (ncc_tracer_config:snapshot/0),
%% written once, before the closure is loaded and anything compiles.
config_env(Token, {Entries, Truncated}) when is_list(Entries), is_boolean(Truncated) ->
    call(Token, {config_env, Entries, Truncated});
config_env(Token, _Error) -> call(Token, config_env_error).

native_patterns(Token, App, Ebin) -> call(Token, {native, bin(App), to_list(Ebin)}).

%% Relocatable builds (S4): the modules of each closure dependency whose
%% beams hold the build's deps or build path, `[{App, Module}]`, named by the
%% worker for a relocation's second build. Sent once, before anything
%% compiles; the collector sets call patterns on an app's holders when its
%% window has closed (holder_patterns/3), as native_patterns/3 does for a
%% natively built dependency.
holders(Token, Holders) -> call(Token, {holders, Holders}).

%% The project's protocol consolidation dir (Mix.Project.consolidation_path/1),
%% named by the driver once the project compile is done (host mode), before
%% finish/2: the final sentinel then accepts the protocol reloads Mix made
%% from it (consolidated_protocol/2).
consolidated(Token, Dir) -> call(Token, {consolidated, to_list(Dir)}).

%% The final sentinel counts only when fired by the process that asked the
%% collector for its nonce, carrying that nonce: a package calling the probe
%% with "__final__" before it tampers with the session proves nothing.
finish(Token, Status) ->
    _ = case call(Token, final_nonce) of
            Nonce when is_binary(Nonce) ->
                quietly(fun() -> fire("__final__:" ++ binary_to_list(Nonce)) end);
            _ -> skip
        end,
    Delivered = delivered(),
    call(Token, {finish, bin(Status), now_ns(), Delivered =:= ok}).

fire(App) -> ?PROBE:fire(to_list(App)).

%% Returns once every trace message generated before the call is written.
%% erlang:halt/0,1 stops the VM without running anything else, so a child
%% VM that halts right after its last compile loses the lines still queued
%% in the collector; a caller that can wait calls this before halting.
flush() ->
    case {delivered(), call(none, flush)} of
        {ok, Reply} -> Reply;
        {_, _} -> {error, undelivered}
    end.

ebin_dir() -> filename:absname(filename:dirname(code:which(?MODULE))).

%% The collector's pid, kept from start: it is not registered, so a package
%% cannot take its name and answer the driver's calls.
collector() -> persistent_term:get(?COLLECTOR, undefined).

%% Stage 1 for one call. A stack the classifier cannot take apart (a frame
%% that is not a 4-tuple, a crash in IsToolchain) is user extent of its own
%% kind, `unjudged`: the event is written, never dropped.
safe_extent(Stack, Depth, IsToolchain, ProcessIsUser) ->
    safe_extent(Stack, Depth, IsToolchain, ProcessIsUser, fun(_File) -> false end).

safe_extent(Stack, Depth, IsToolchain, ProcessIsUser, IsScript) ->
    try ncc_tracer_stack:extent(Stack, Depth, IsToolchain, ProcessIsUser, IsScript) of
        toolchain -> toolchain;
        {user, Kind, _First, _User} = Extent when is_atom(Kind) -> Extent;
        _Other -> {user, unjudged, none, none}
    catch
        _:_ -> {user, unjudged, none, none}
    end.

%% --- start ---------------------------------------------------------------

start(_Role, false, _App, _Before) -> {error, no_trace_dir};
start(Role, Dir, App, Before) ->
    %% The set returns the old value; the second set reads back what the
    %% first one left, which is the depth every stack is judged against.
    _ = erlang:system_flag(backtrace_depth, ?DEPTH),
    Depth = erlang:system_flag(backtrace_depth, ?DEPTH),
    ok = erlang_resolver(Role),
    ok = load_probe(),
    ok = load_digest(Role),
    Script = mix_script(Role),
    Libs = start_libs(),
    Parent = self(),
    Opts = [monitor, {priority, high}, {message_queue_data, off_heap},
            {max_heap_size, #{size => env_int("NCC_TRACE_MAX_HEAP_WORDS", 33554432),
                              kill => true, error_logger => false}}],
    {Pid, Ref} = spawn_opt(fun() -> init(Parent, Role, Dir, App, Depth, Script, Libs, Before) end,
                           Opts),
    receive
        {Pid, ready, Token} ->
            erlang:demonitor(Ref, [flush]),
            persistent_term:put(?COLLECTOR, Pid),
            ok = set_child_env(Role),
            {ok, Token};
        {'DOWN', Ref, process, Pid, Reason} -> {error, Reason}
    after ?TIMEOUT -> {error, timeout}
    end.

%% The Mix VM resolves names with Erlang's own resolver (/etc/hosts, then DNS
%% as /etc/resolv.conf sets it), as the worker does (NccWorker.ProcessSweep).
%% The native one is a port program, inet_gethost, that the VM restarts the
%% moment it is killed: a compile that looked a name up (rustler_precompiled's
%% download) would leave one no window sweep (ncc_tracer_sweep) could clear.
%% A native resolver already running is stopped; it is a temporary child, and
%% nothing starts it again but a direct call into it. Child VMs (rebar3) end
%% inside a window, their resolver with them.
erlang_resolver(main) ->
    _ = quietly(fun() -> inet_db:set_lookup([file, dns]) end),
    _ = case whereis(inet_gethost_native) of
            undefined -> ok;
            _Pid -> quietly(fun() -> supervisor:terminate_child(kernel_safe_sup,
                                                                 inet_gethost_native_sup) end)
        end,
    ok;
erlang_resolver(child) -> ok.

%% The Mix VM's collector digests every build after its window, by which
%% time Mix has pruned the code path to the project's; so the module is
%% loaded now. Child VMs never digest.
load_digest(main) ->
    _ = quietly(fun() -> code:ensure_loaded(ncc_tracer_digest) end),
    ok;
load_digest(child) -> ok.

refuse_start(false, Why) -> {error, binary_to_atom(Why)};
refuse_start(Dir, Why) ->
    Line = json:encode(#{kind => refused_start, why => Why}),
    ok = file:write_file(filename:join(Dir, "trace-main.jsonl"), [Line, $\n]),
    {error, binary_to_atom(Why)}.

%% Every BEAM the compile starts from here on (rebar3 above all) starts its
%% own tracer first: ERL_AFLAGS, not ERL_FLAGS, because an escript's
%% `-run escript start` would halt the VM before a later `-s` runs.
set_child_env(main) ->
    Old = case os:getenv("ERL_AFLAGS") of
              false -> "";
              Value -> Value ++ " "
          end,
    Flags = Old ++ "-pa " ++ quote(ebin_dir()) ++ " -s ncc_tracer start_child",
    true = os:putenv("ERL_AFLAGS", Flags),
    ok;
set_child_env(child) -> ok.

%% erlexec splits ERL_AFLAGS on blanks unless they are inside double quotes.
quote(Path) ->
    [$" | lists:flatmap(fun($") -> "\\\"";
                           ($\\) -> "\\\\";
                           (C) -> [C]
                        end, Path)] ++ [$"].

child_app() ->
    case os:getenv("REBAR_BARE_COMPILER_OUTPUT_DIR") of
        false -> "unknown";
        Path -> filename:basename(Path)
    end.

file_name(main, _App) -> "trace-main.jsonl";
file_name(child, App) -> "trace-child-" ++ App ++ "-" ++ os:getpid() ++ ".jsonl".

%% The sentinel probe: loaded from a binary with no file name, so its frames
%% are user extent by the same rule as package code, and its getenv names the
%% window it was fired in. Not a tail call, so its frame stays on the stack.
load_probe() ->
    case code:is_loaded(?PROBE) of
        {file, _} -> ok;
        false ->
            Src = "-module(ncc_tracer_probe).\n-export([fire/1]).\n"
                  "fire(App) -> V = os:getenv(\"" ?SENTINEL "\" ++ App), {App, V}.\n",
            {ok, ?PROBE, Bin} = compile:forms(forms(Src, 1, []), [binary, return_errors]),
            {module, ?PROBE} = code:load_binary(?PROBE, "", Bin),
            ok
    end.

forms(Src, Line, Acc) ->
    case erl_scan:tokens([], Src, Line) of
        {done, {ok, Tokens, End}, Rest} ->
            {ok, Form} = erl_parse:parse_form(Tokens),
            forms(Rest, End, [Form | Acc]);
        _ -> lists:reverse(Acc)
    end.

%% --- collector -------------------------------------------------------------

init(Parent, Role, Dir, App, Depth, Script, Libs, Before) ->
    put(mix_script, Script),
    put(driver, Parent),
    put(roots, roots()),
    File = filename:join(Dir, file_name(Role, App)),
    {ok, Fd} = file:open(File, [write, raw, binary]),
    ok = buffered(Role),
    %% Our own session (OTP 27+): a package's erlang:trace/3 or trace_pattern
    %% acts on the legacy session and cannot switch this one off. Its weak
    %% handle is {Name, Id}: a random name keeps it from being guessed; the
    %% calls that list or act on sessions are integrity patterns.
    Session = trace:session_create(binary_to_atom(<<"ncc_tracer_", (random_hex())/binary>>),
                                   self(), []),
    Flags = [call, procs, set_on_spawn, monotonic_timestamp],
    _ = trace:process(Session, existing, true, Flags),
    _ = trace:process(Session, self(), false, Flags),
    Token = random_hex(),
    Sweep = sweep_setting(Role),
    St0 = #st{fd = Fd, file = File, session = Session, set_depth = Depth, depth = Depth,
              token = Token, sweep = Sweep,             initial = maps:from_keys(erlang:processes(), true),
             max_calls = env_int("NCC_TRACE_MAX_CALLS", 20000000),
             max_user = env_int("NCC_TRACE_MAX_USER_EVENTS", 200000),
             max_queue = env_int("NCC_TRACE_MAX_QUEUE", 2000000),
             max_value_bytes = env_int("NCC_TRACE_MAX_VALUE_BYTES", ?MAX_VALUE_BYTES)},
    %% Before any pattern is set: loading a module makes the code server
    %% search the path, and those reads would be traced (pattern/3 loads
    %% each patterned module too; these are loaded first for the same reason).
    Unloaded = load_uses(),
    put(preloaded_md5, preloaded_md5s()),
    put(owned_md5, owned_md5s()),
    Patterns = ncc_tracer_channels:patterns() ++ spawn_patterns() ++ role_patterns(Role)
        ++ [?PREPARE_LOADING, ?FINISH_LOADING],
    Canaries = canary_patterns(),
    _ = [quietly(fun() -> code:ensure_loaded(M) end) || {M, _, _} <- Patterns ++ Canaries],
    ok = hide_ebin(),
    Wanted =[wanted(Session, MFA, match_spec(MFA, Role, Depth))
              || MFA <- Patterns ++ mix_patterns(Role)]
        ++ [wanted(Session, MFA, ?NEVER) || MFA <- Canaries],
    Preloaded = preloaded(Before, Role),
    put(preloaded, Preloaded),
    {Installed, Skip} = installed(Role, Before, Preloaded),
    put(installed, Installed),
    put(installed_apps, installed_apps(Role)),
    put(apps_before, maps:from_keys([atom_to_binary(A) || {A, _, _} <- application:loaded_applications()],
                                    true)),
    Calls = app_calls(Preloaded),
    put(app_calls, Calls),
    %% Never a probe or call pattern without a module to filter it to: an
    %% empty set would trace every call.
    ProbeWanted = [wanted(Session, MFA, MS)
                   || MFA <- ncc_tracer_channels:probe_mfas(),
                      MS <- [probe_spec(Role, MFA, Preloaded, Skip, Depth)], MS =/= []]
        ++ [wanted(Session, {M, '_', '_'}, match_spec(M, Role, Depth))
            || M <- maps:keys(Calls)],
    write(St0, maps:merge((start_line(Role, App, Depth))#{mix_script => script_bin(Script),
                                                          preloaded => Preloaded,
                                                          window_sweep => Sweep =/= off},
                          libs_fields(Libs))),
    St = watcher(St0#st{wanted = Wanted ++ ProbeWanted, libs = Libs, unloaded = Unloaded}),
    Parent ! {self(), ready, Token},
    loop(St).

%% Spawned by the untraced collector after the existing processes were
%% traced, so it is not traced itself; each monitors the other.
watcher(#st{file = File} = St) ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> watch(Self, File) end),
    St#st{watcher = Pid, wref = Ref}.

%% Bounded like a user event (capped_line/2): a package killing the watcher
%% in a loop overflows the trace rather than filling the disk.
watcher_down(Reason, St) ->
    Line = #{kind => watcher_down, reason => reason_bin(Reason), ts => now_ns()},
    watcher(capped_line(Line, St#st{tampered = true})).

%% A collector that dies other than by finishing (killed by a package, by
%% its max_heap_size, by a crash) leaves a line saying so; in a child VM
%% that is the only trace of it.
watch(Collector, File) ->
    Ref = erlang:monitor(process, Collector),
    receive
        {'DOWN', Ref, process, Collector, normal} -> ok;
        {'DOWN', Ref, process, Collector, Reason} ->
            Line = json:encode(#{kind => collector_down, reason => reason_bin(Reason),
                                 ts => now_ns()}),
            _ = file:write_file(File, [Line, $\n], [append, raw]),
            ok
    end.

reason_bin(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason_bin(Reason) -> ncc_tracer_channels:term_bin(Reason).

%% A pattern only for the check (patterns_check/2) to find gone, on
%% module_info/0 (every module's, and never hot) of each module whose frames
%% are trusted by name, or by the verdict the collector takes on the code
%% loaded when it gets to an event rather than when the call was made:
%% loading other code under the name, even for one call with the
%% toolchain's put back before the collector looks, drops it. The path
%% internals (ncc_tracer_channels:path_os_frames/0: such a read is only
%% counted), the family-only os:type/0 callers (os_family_callers/0,
%% caller_kind), the type checker's pool-size frame
%% (checker_pool_frames/0, first_kind and caller_kind), the wrappers strip/3
%% skips (ncc_tracer_stack:wrappers/0), the code-loading shapes' modules
%% (code_load/5), the @behaviour lookup's frames (attribute_lookup/1),
%% the epp server whose
%% predefined-macro reads the judge ignores, and erlang (the judge's
%% big_binary_to_int/2 caller). Sticky modules are no exception:
%% erlang:load_module/2 does not ask the code server. A canary is held only
%% while its module, when loaded, exports module_info/0 (canary_held/2), so a
%% forged module cannot pass by leaving the canary's function out.
canary_patterns() ->
    Named = [binary_to_atom(M)
             || {M, _F, _A} <- ncc_tracer_channels:path_os_frames()
                    ++ ncc_tracer_channels:os_family_callers()
                    ++ ncc_tracer_channels:checker_pool_frames()]
        ++ [M || {M, _F, _A} <- ncc_tracer_stack:attribute_lookup_frames()],
    Shapes = [M || Shape <- ncc_tracer_stack:code_loading_shapes(
                               erlang:system_info(otp_release)),
                   {M, _F, _A} <- Shape],
    [{M, module_info, 0}
     || M <- lists:usort(Named ++ ncc_tracer_stack:wrappers() ++ Shapes ++ [epp, erlang])].

role_patterns(child) -> [{compile, file, 2}];
role_patterns(main) -> [].

%% Mix's compile entry points, in the Mix VM, of the modules Mix has loaded
%% already: never loaded for a pattern (ncc_tracer_channels mix_patterns/0).
mix_patterns(main) ->
    [MFA || {M, _, _} = MFA <- ncc_tracer_channels:mix_patterns(), erlang:module_loaded(M)];
mix_patterns(child) -> [].

%% Every spawn BIF: a spawn made in user extent makes the child a user
%% process, whatever it runs (Task.async(System, :get_env, [..]) from a
%% module body leaves only toolchain frames in the child).
spawn_patterns() ->
    [{erlang, F, A} || {F, A} <- erlang:module_info(exports), lists:member(F, ?SPAWNS)].

pattern(Session, {M, _, _} = MFA, MS) ->
    case code:ensure_loaded(M) of
        {module, M} -> _ = trace:function(Session, MFA, MS, [global]), ok;
        _ -> ok
    end.

%% Sets a pattern and remembers whether its module was loaded: a module that
%% was loaded and traced must stay so (Elixir modules and crypto are not
%% sticky, so a package can delete and purge one, use it untraced after a
%% reload, and delete it again).
wanted(Session, {M, _, _} = MFA, MS) ->
    ok = pattern(Session, MFA, MS),
    {MFA, MS, erlang:module_loaded(M)}.

%% A reloaded module (code:load_file/1 after code:unstick_mod/1 for a kernel
%% module, any purge and load for the rest) comes back without its patterns,
%% and so does a module that could not be loaded at start and is loaded now.
%% Every check sets the missing ones again and reports the window.
%% A session that is gone (destroyed by a package, or by our own overflow)
%% makes trace:info/3 fail: that is a failed check too.
%% When: sentinel, final (the final sentinel) or close (a window close or
%% the finish).
patterns_check(#st{unpatterned = Lost, overflow = Overflow} = St0, When) ->
    {Patterned, St} = case Overflow of
                          true -> {false, St0};
                          false -> repatterned(St0, When)
                      end,
    Ok = Patterned andalso not Lost,
    {Ok, St#st{unpatterned = When =/= close andalso not Ok}}.

repatterned(#st{session = Session, wanted = Wanted} = St, When) ->
    try
        Checked = [rewanted(Session, W, When, St) || W <- Wanted],
        {lists:all(fun({Ok, _}) -> Ok end, Checked), St#st{wanted = [W || {_, W} <- Checked]}}
    catch
        _:_ -> {false, St}
    end.

rewanted(Session, {MFA, MS, Loaded} = W, When, St) ->
    case traced(Session, MFA, Loaded) andalso canary_held(MFA, MS) of
        true -> {true, W};
        false ->
            %% Patterned again (and loaded, if it is not) before it is judged.
            Again = wanted(Session, MFA, MS),
            {When =:= final andalso consolidated_protocol(MFA, St), Again}
    end.

%% The one reload the final sentinel accepts, once it has patterned the
%% module again: Mix's protocol consolidation, which runs at the end of the
%% project compile in host mode, after the last window, purges every
%% protocol it consolidated, and the next use loads it from the project's
%% consolidated dir, without the patterns a natively built dependency's
%% modules carry (native/3). Only a module of such a dependency, only from
%% the dir the driver named (consolidated/2), only a protocol (it exports
%% __protocol__/1), and only when the code loaded now is that file's (same
%% module md5). Any other lost pattern, and this one in a window or before
%% the dir is named, still fails the check. Calls into that module between
%% the purge and the final sentinel are not traced: they come after every
%% window closed and every built digest was taken, so they cannot reach a
%% judged beam.
consolidated_protocol({M, _, _}, #st{consolidated = Dir, native = Native})
  when is_list(Dir), is_map_key(M, Native) ->
    Beam = filename:join(Dir, atom_to_list(M) ++ ".beam"),
    try
        code:which(M) =:= Beam
            andalso lists:member({'__protocol__', 1}, erlang:get_module_info(M, exports))
            andalso beam_lib:md5(Beam) =:= {ok, {M, erlang:get_module_info(M, md5)}}
    catch
        _:_ -> false
    end;
consolidated_protocol(_MFA, _St) -> false.

traced(Session, {M, F, A}, WasLoaded) ->
    case erlang:module_loaded(M) of
        false -> not WasLoaded;
        true ->
            lists:all(fun(MFA) -> trace:info(Session, MFA, traced) =:= {traced, global} end,
                      concrete(M, F, A))
    end.

%% A canary's module, when loaded, must still export the canary's function:
%% traced/3 takes a function the module does not export as nothing to check.
canary_held({M, F, A}, ?NEVER) ->
    not erlang:module_loaded(M) orelse erlang:function_exported(M, F, A);
canary_held(_MFA, _MS) -> true.

concrete(M, '_', '_') -> [{M, F, A} || {F, A} <- M:module_info(exports)];
concrete(M, F, A) ->
    case erlang:function_exported(M, F, A) of
        true -> [{M, F, A}];
        false -> []
    end.

%% --- modules the tracer loaded ----------------------------------------------

loaded() -> maps:from_keys([M || {M, _} <- code:all_loaded()], true).

%% The tracer's Erlang modules and every module they call, loaded now: one
%% the collector loaded only later, mid-compile (json, the first time it
%% writes a line), would be loaded under the trace without being in
%% `preloaded`. Returns the ones that could not be loaded. Not the driver,
%% a Mix task that runs in the Mix VM only, before this.
load_uses() ->
    Uses = (tracer_owned() -- [?DRIVER]) ++ uses(),
    _ = [quietly(fun() -> code:ensure_loaded(M) end) || M <- Uses],
    [M || M <- Uses, not erlang:module_loaded(M)].

uses() ->
    lists:usort([M || Own <- tracer_owned(), Own =/= ?PROBE, Own =/= ?DRIVER,
                      {M, _, _} <- imports(Own),
                      not lists:member(M, tracer_owned())]).

imports(Own) ->
    try beam_lib:chunks(code:which(Own), [imports]) of
        {ok, {_, [{imports, Imports}]}} -> Imports;
        _ -> []
    catch _:_ -> []
    end.

%% The tracer's own modules, every one in its ebin whether loaded or not
%% (the ebin is on the code path, so a probe would find any of them), the
%% driver and the sentinel probe. None exists in an untraced compile.
tracer_owned() ->
    Beams = [list_to_atom(filename:basename(F, ".beam"))
             || F <- filelib:wildcard("ncc_tracer*.beam", ebin_dir())],
    lists:usort([?PROBE, ?MODULE, ?DRIVER | Beams]).

loaded_by_mix() -> ?LOADED_BY_MIX.

%% No untraced compile has the tracer's ebin on its code path (coverage
%% drop 2026-11-22, F1). By the time this runs every module in it is loaded
%% (load_uses/0; in the Mix VM the driver runs already), so it leaves the
%% path: a scan of the path then finds what an untraced compile's finds
%% (Mix.Task.load_all/0 in a dependency's mix.exs, which Mix evaluates
%% before its first compile prunes the path). Before any pattern is set, so
%% the code server's work is no event. Every entry that names the dir goes
%% (a child VM's ERL_AFLAGS can name it more than once); an entry left
%% behind only leaves a scan's probe of a tracer module unjudged, as
%% before. Child VMs still find the tracer: their ERL_AFLAGS name the dir
%% by ebin_dir/0, the loaded module's own file.
hide_ebin() ->
    Ebin = ebin_dir(),
    _ = [code:del_path(P) || P <- code:get_path(), filename:absname(P) =:= Ebin],
    ok.

%% Every module loaded now that was not loaded before the tracer started
%% (nor, in the Mix VM, by Mix anyway), and every tracer-owned one, with the
%% application it belongs to: what a package's compile-time probe could find
%% loaded only because of the trace.
preloaded(Before, Role) ->
    Owned = tracer_owned(),
    Anyway = case Role of
                 main -> ?LOADED_BY_MIX;
                 child -> []
             end,
    New = [M || {M, _} <- code:all_loaded(), not is_map_key(M, Before),
                not lists:member(M, Owned), not lists:member(M, Anyway)],
    maps:from_list([{atom_to_binary(M), app_of(M)} || M <- New]
                   ++ [{atom_to_binary(M), <<"ncc_tracer">>} || M <- Owned]).

app_of(M) ->
    case application:get_application(M) of
        {ok, App} -> atom_to_binary(App);
        undefined -> app_from_path(code:which(M))
    end.

%% <lib>/<app>-<vsn>/ebin/<m>.beam (or <lib>/<app>/ebin, Elixir's) -> <app>.
app_from_path(Path) when is_list(Path), Path =/= [] ->
    Dir = filename:basename(filename:dirname(filename:dirname(Path))),
    list_to_binary(hd(string:split(Dir, "-")));
app_from_path(_Other) -> <<"unknown">>.

%% Applications every compile has on its code path: a call into one of
%% their modules works untraced too.
-define(ALWAYS_ON_PATH, [<<"kernel">>, <<"stdlib">>, <<"elixir">>, <<"compiler">>, <<"logger">>]).

%% The modules we loaded whose application an untraced compile may not have
%% on its path (httpc, ssl, dbg, ...), as #{Module => App}: every call into
%% one is traced, and one from package code is judged against the
%% applications it lists (NccWorker.Portability.Probes). Not the tracer's
%% own (the ncc_tracer patterns cover them), and not crypto, which a child
%% VM loads for rebar3's own hashing.
app_calls(Preloaded) ->
    maps:from_list([{binary_to_atom(M), App} || {M, App} <- maps:to_list(Preloaded),
                    not lists:member(App, [<<"ncc_tracer">> | ?ALWAYS_ON_PATH]),
                    M =/= <<"crypto">>]).

%% In the Mix VM a probe of any module fires but one in Skip (#{Module =>
%% true}: one clause, a map lookup, not a clause per module): a probe of a
%% module we loaded is judged as such, of an installed application's as
%% `otp_app`, and the package's of any other (`by_package`) against the
%% closure (NccWorker.Portability.Probes). In a child VM (rebar3, which
%% prunes nothing) only a probe of a module we loaded fires.
probe_spec(main, MFA, _Preloaded, Skip, Depth) ->
    [{probe_head(MFA, '$1'), [{'not', {is_map_key, '$1', {const, Skip}}}],
      [{message, {current_stacktrace, Depth}}]}];
probe_spec(child, MFA, Preloaded, _Skip, Depth) ->
    [{probe_head(MFA, binary_to_atom(M)), [], [{message, {current_stacktrace, Depth}}]}
     || M <- maps:keys(Preloaded)].

probe_head({erlang, function_exported, 3}, M) -> [M, '_', '_'];
probe_head(_MFA, M) -> [M].

%% Every module of an installed OTP or Elixir application, as
%% #{Module => App}, both binaries (an every-path application's too, round
%% 2: whether one is loaded now is what other compile-time code did):
%% Mix compiles a dependency on a code path pruned to the applications its
%% closure lists, Mix.install does not (`prune_code_paths: false`), so a
%% probe of one answers differently there (NccWorker.Portability.Probes,
%% which the event's `otp_app` names it to). Read from the installs' ebin
%% dirs, not the code path. Not a module loaded before the tracer started
%% or one Mix loads in every compile anyway (loaded either way, as
%% preloaded/2 takes them), nor one the tracer loaded (`preloaded`, judged
%% as such). The Mix VM only: rebar3 prunes nothing. Listed in a process of
%% its own, so the listing's garbage never counts against the collector's
%% max_heap_size; a listing that fails fails the tracer's start, never
%% leaves the set empty. With it, the modules no probe of which is traced
%% (probe_spec/5): those loaded before the tracer started or by Mix anyway,
%% all but the ones we loaded.
installed(main, Before0, Preloaded) ->
    Before = every_vm(Before0),
    {Pid, Ref} = spawn_monitor(fun() ->
                                       exit({installed, installed_modules(Before, Preloaded),
                                             skipped(Before, Preloaded)})
                               end),
    receive
        {'DOWN', Ref, process, Pid, {installed, Installed, Skip}} -> {Installed, Skip};
        {'DOWN', Ref, process, Pid, Reason} -> erlang:error({installed_modules, Reason})
    end;
installed(child, _Before, _Preloaded) -> {#{}, #{}}.

%% Round 3 (R2-6): of the modules loaded before the tracer started, only
%% those a bare VM of this toolchain has loaded too (`NCC_TRACE_BASE`, which
%% NccWorker.Tracer writes from `elixir -e`: erts's, kernel's, stdlib's and
%% Elixir's boot) are taken as loaded for the user. One Mix, Hex or the
%% driver loaded is traced and judged like any other. Without the list,
%% erts's preloaded modules only.
every_vm(Before) ->
    Base = case os:getenv("NCC_TRACE_BASE") of
               false -> erlang:pre_loaded();
               Path -> base_list(file:read_file(Path))
           end,
    maps:with(Base, Before).

base_list({ok, Bin}) ->
    [binary_to_atom(L) || L <- binary:split(Bin, <<"\n">>, [global, trim_all])];
base_list(_Error) -> erlang:pre_loaded().

%% Round 2 (R1-A): an every-path application's module not loaded yet is
%% traced too: whether it is loaded now is what other compile-time code
%% did.
skipped(Before, Preloaded) ->
    maps:without([binary_to_atom(M) || M <- maps:keys(Preloaded)],
                 maps:merge(Before, maps:from_keys(?LOADED_BY_MIX, true))).

installed_modules(Before, Preloaded) ->
    Libs = [filename:join(code:root_dir(), "lib") | elixir_lib()],
    maps:from_list([{atom_to_binary(M), App}
                    || Lib <- Libs, Beam <- filelib:wildcard("*/ebin/*.beam", Lib),
                       App <- [app_from_path(filename:join(Lib, Beam))],
                       M <- [list_to_atom(filename:basename(Beam, ".beam"))],
                       not is_map_key(M, Before),
                       not lists:member(M, ?LOADED_BY_MIX),
                       not is_map_key(atom_to_binary(M), Preloaded)]).

%% The installed OTP and Elixir applications off every compile's path, as
%% #{App => true}: an application probe of one is named `otp_app`.
installed_apps(main) ->
    maps:from_keys([App || Lib <- [filename:join(code:root_dir(), "lib") | elixir_lib()],
                           File <- filelib:wildcard("*/ebin/*.app", Lib),
                           App <- [list_to_binary(filename:basename(File, ".app"))],
                           not lists:member(App, ?ON_EVERY_PATH)], true);
installed_apps(child) -> #{}.

elixir_lib() ->
    case code:lib_dir(elixir) of
        Dir when is_list(Dir) -> [filename:dirname(Dir)];
        _ -> []
    end.

%% A probe's application, as this VM's `preloaded` names it, the installed
%% application of one we did not load (`installed`), whether it is the
%% lookup `@behaviour` makes (attribute_lookup/2), and for it or a call
%% into such a module whether the type checker made it
%% (ncc_tracer_stack:checker/2; each frame's kind looked up afresh).
probed({probe, #{module := Module} = Arg}, Stack) ->
    {probe, Arg#{app => maps:get(Module, get(preloaded), null),
                 otp_app => maps:get(Module, get(installed), null),
                 attribute => attribute_lookup(Stack),
                 by_package => made_by_package(Stack),
                 checker => checker(Stack)}};
probed({app_probe, #{app := App} = Arg}, _Stack) ->
    Otp = case is_map_key(App, get(installed_apps)) of
              true -> App;
              false -> null
          end,
    {app_probe, Arg#{otp_app => Otp, loaded_before => is_map_key(App, get(apps_before))}};
probed({install, #{what := all_available} = Arg}, Stack) ->
    {install, Arg#{checker => checker(Stack)}};
probed({app_call, Arg}, Stack) ->
    {app_call, Arg#{checker => checker(Stack), caller_app => caller_app(caller(Stack))}};
probed(Class, _Stack) -> Class.

%% For a call into a module we loaded, the installed OTP application whose
%% code made it: the frame right below the call runs a module whose object
%% code is <code:lib_dir()>/<app>[-<vsn>]/ebin/<module>.beam, the beam on
%% disk there being the code loaded for it (toolchain_module/1, by md5: a
%% package could load its own module of that name, or record that file for
%% its own code). null for any other frame, module or place it was loaded
%% from. The judge allows the call only when that application's .app lists
%% the called module's (NccWorker.Portability.Probes).
caller_app({M, _F, _A, _Location}) when is_atom(M) ->
    try installed_app(M, code:which(M), toolchain_module(M)) catch _:_ -> null end;
caller_app(_Frame) -> null.

installed_app(M, Path, true) when is_list(Path), Path =/= [] ->
    Lib = filename:split(norm(code:lib_dir())),
    Beam = atom_to_list(M) ++ ".beam",
    Parts = filename:split(norm(Path)),
    case length(Parts) =:= length(Lib) + 3 andalso lists:split(length(Lib), Parts) of
        {Lib, [AppVsn, "ebin", Beam]} -> list_to_binary(hd(string:split(AppVsn, "-")));
        _ -> null
    end;
installed_app(_M, _Path, _Toolchain) -> null.

checker(Stack) ->
    try ncc_tracer_stack:checker(Stack, fun toolchain_module/1)
    catch _:_ -> false
    end.

made_by_package(Stack) ->
    try ncc_tracer_stack:made_by_package(Stack, fun toolchain_module/1)
    catch _:_ -> true
    end.

attribute_lookup(Stack) ->
    try ncc_tracer_stack:attribute_lookup(Stack, fun toolchain_module/1)
    catch _:_ -> false
    end.

%% A call into a module we loaded that no channel pattern covers.
app_call(M, F, Args) ->
    case get(app_calls) of
        #{M := App} ->
            case ncc_tracer_channels:patterned(M, F, length(Args)) of
                true -> false;
                false -> {app_call, #{module => atom_to_binary(M), app => App}}
            end;
        _ -> false
    end.

match_spec(?PREPARE_LOADING, _Role, _Depth) -> [{'_', [], [{message, code_load}, {return_trace}]}];
match_spec(?FINISH_LOADING, _Role, _Depth) ->
    [{'_', [], [{message, code_load}, {exception_trace}]}];
match_spec({compile, file, 2}, child, _Depth) -> [{'_', [], [{return_trace}]}];
match_spec({erlang, process_info, 2}, _Role, Depth) ->
    Msg = {message, {current_stacktrace, Depth}},
    [{['_', Item], [], [Msg]} || Item <- [dictionary, backtrace, messages, {dictionary, '_'}]]
        ++ [{['_', '$1'], [{is_list, '$1'}], [Msg]}];
match_spec(MFA, _Role, Depth) ->
    Msg = {message, {current_stacktrace, Depth}},
    Body = [Msg | return_action(MFA)],
    case ncc_tracer_channels:mix_state_heads(MFA) of
        undefined -> [{'_', [], Body}];
        Heads -> [{Head, Guards, Body} || {Head, Guards} <- Heads]
    end.

%% exception_trace: a return_from message on return, an exception_from one
%% when the call raises, so every pushed frame is popped
%% (ncc_tracer_channels:returned_mfas/0). The message copies the returned
%% term into the collector's mailbox, once per return, however big: that is
%% accepted, as the copy lives only until the message is handled (the value
%% is sized before it is encoded, and what is written is bounded by
%% MAX_VALUE_BYTES), the queue stays under max_queue like any other trace
%% message, and these reads are rare next to the file and code reads.
return_action({M, F, A}) ->
    case ncc_tracer_channels:returned_mfa(M, F, A) of
        true -> [{exception_trace}];
        false -> []
    end;
return_action(_Module) -> [].

loop(St) ->
    receive
        {trace_ts, _Pid, _What, _, _} = Msg -> loop(collected(traced(Msg, St)));
        {trace_ts, _Pid, _What, _, _, _} = Msg -> loop(collected(traced(Msg, St)));
        {ncc_call, From, Ref, Auth, Req} when Auth =:= St#st.token; Req =:= flush ->
            {Reply, St1} = request(Req, From, St),
            ok = write_out(St1#st.fd),
            From ! {Ref, Reply},
            continue(Req, St1);
        {ncc_call, From, Ref, _BadAuth, Req} ->
            loop(forged(From, Ref, Req, St));
        {ncc_call, From, Ref, Req} ->
            loop(forged(From, Ref, Req, St));
        {'DOWN', Ref, process, _Pid, Reason} when Ref =:= St#st.wref ->
            loop(watcher_down(Reason, St));
        _Other ->
            loop(St)
    end.

%% A trace message carries a copy of its call's arguments, and a spawn's of
%% its fun with everything in the fun's environment: several copies for one
%% spawn (each traced spawn call on the way, the `spawn` and `spawned`
%% messages), and the compiler spawns the checker of every module it
%% compiles with that module in the environment, tens of MB for a large
%% generated one. Each copy is garbage once handled, but a copy live at a
%% minor collection moves to the old heap and stays there until a major
%% one, and a collection that meets several such copies needs more than
%% max_heap_size: the collector was killed for the size of the code it
%% traces, every copy already handled (date_time_parser, poison). So once
%% the heap is ?GC_GROWTH words past twice what the last collection left
%% (a heap and an old heap of live data), it is collected as soon as the
%% message in hand is handled: no handled copy survives the next large
%% message. One message too large to copy under max_heap_size still kills
%% it (tabler_icons: a live 11M-word message).
collected(#st{gc_at = At} = St) ->
    case process_info(self(), total_heap_size) of
        {total_heap_size, Words} when Words > At ->
            true = garbage_collect(),
            {total_heap_size, Left} = process_info(self(), total_heap_size),
            St#st{gc_at = 2 * Left + ?GC_GROWTH};
        _ ->
            St
    end.

traced({trace_ts, Pid, call, {erts_internal, prepare_loading, [M, Bin]}, code_load, Ts}, St) ->
    put({preparing, Pid}, code_prepared(M, Bin, Ts)),
    St;
traced({trace_ts, Pid, return_from, ?PREPARE_LOADING, Prepared, _Ts}, St) ->
    prepared_ref(erase({preparing, Pid}), Prepared),
    St;
traced({trace_ts, Pid, call, {erlang, finish_loading, [Refs]}, code_load, Ts}, St) ->
    put({finishing, Pid}, Ts),
    code_finished(Refs, Ts),
    St;
traced({trace_ts, Pid, return_from, ?FINISH_LOADING, Result, _Ts}, St) ->
    finish_returned(erase({finishing, Pid}), Result),
    St;
traced({trace_ts, Pid, exception_from, ?FINISH_LOADING, _Exception, _Ts}, St) ->
    _ = erase({finishing, Pid}),
    St;
traced({trace_ts, Pid, call, {M, F, Args}, Stack, Ts}, St) ->
    call_event(Pid, M, F, Args, Stack, Ts, pending(Pid, M, F, Args, St));
traced({trace_ts, Pid, call, {compile, file, [Src | Rest]}, _Ts}, St) ->
    St#st{sources = maps:put(Pid, {Src, outdir(Rest)}, St#st.sources)};
traced({trace_ts, Pid, call, {M, F, Args}, Ts}, St) ->
    %% A call with no stack: our match spec was replaced. Unjudged.
    call_event(Pid, M, F, Args, no_stack, Ts, pending(Pid, M, F, Args, St));
traced({trace_ts, Pid, return_from, {compile, file, 2}, Result, Ts}, St) ->
    compiled(Pid, Result, Ts, St);
traced({trace_ts, Pid, return_from, {M, F, A}, Result, _Ts}, St) ->
    returned(Pid, M, F, A, {value, Result}, St);
traced({trace_ts, Pid, exception_from, {M, F, A}, _Exception, _Ts}, St) ->
    returned(Pid, M, F, A, exception, St);
traced({trace_ts, Parent, spawn, Child, MFA, _Ts}, St) ->
    spawned(Child, Parent, MFA, St);
traced({trace_ts, Child, spawned, Parent, _MFA, _Ts}, St) ->
    case is_map_key(Child, St#st.procs) of
        true -> St;
        false -> St#st{parents = maps:put(Child, Parent, St#st.parents)}
    end;
traced({trace_ts, Pid, exit, _Reason, _Ts}, St) ->
    _ = erase({preparing, Pid}),
    %% Killed inside erlang:finish_loading/1: its code may be in, and what
    %% it would have returned (finish_returned/2) is not known.
    _ = is_integer(erase({finishing, Pid})) andalso swapped(finish_loading),
    St#st{procs = maps:remove(Pid, St#st.procs), spawning = maps:remove(Pid, St#st.spawning),
          parents = maps:remove(Pid, St#st.parents), returns = maps:remove(Pid, St#st.returns)};
traced(_Msg, St) -> St.

%% Every return-traced call pushes one frame, whatever its extent: its
%% return pops it. user_line/4 turns the top frame into the call's id when
%% it writes the call's event; any other call's frame stays `skip`.
pending(_Pid, _M, _F, _Args, #st{overflow = true} = St) -> St;
pending(Pid, M, F, Args, #st{returns = Returns} = St) ->
    case ncc_tracer_channels:returned_mfa(M, F, length(Args)) of
        true -> St#st{returns = Returns#{Pid => [skip | maps:get(Pid, Returns, [])]}};
        false -> St
    end.

%% A return pops its frame; a frame with an id writes a `returned` line,
%% which names its value by value_id (stored/2) or carries a marker.
returned(_Pid, _M, _F, _A, _Outcome, #st{overflow = true} = St) -> St;
returned(Pid, M, F, A, Outcome, #st{returns = Returns} = St) ->
    case {ncc_tracer_channels:returned_mfa(M, F, A), maps:get(Pid, Returns, [])} of
        {true, [Top | Rest]} ->
            St1 = St#st{returns = put_frames(Pid, Rest, Returns)},
            case Top of
                {call, Id, Args} ->
                    Term = ncc_tracer_channels:returned_term(M, F, Args, Outcome),
                    {Ref, St2} = value_ref(Term, St1),
                    counted_line(Ref#{kind => returned, call_id => Id}, St2);
                skip ->
                    St1
            end;
        _ ->
            St
    end.

value_ref({recorded, Term}, St) ->
    case ncc_tracer_channels:value_etf(Term) of
        {ok, Etf} -> stored(Etf, St);
        unrecordable -> {#{value => <<"unrecordable">>}, St}
    end;
value_ref(Marker, St) -> {#{value => Marker}, St}.

%% Each distinct value is written once, in a `value` line, keyed by its
%% deterministic ETF itself (exact: no hash can collide); every later read
%% of it names the same value_id. A value that would take the value lines
%% past max_value_bytes is `unrecordable`, never an overflow. The map holds
%% at most the budget's worth of binaries.
stored(Etf, #st{values = Values, value_bytes = Bytes} = St) ->
    case Values of
        #{Etf := VId} ->
            {#{value_id => VId}, St};
        _ ->
            Size = (byte_size(Etf) * 4 + 2) div 3,
            case Bytes + Size > St#st.max_value_bytes of
                true ->
                    {#{value => <<"unrecordable">>}, St};
                false ->
                    VId = map_size(Values) + 1,
                    write(St, #{kind => value, value_id => VId,
                                value => ncc_tracer_channels:value_b64(Etf)}),
                    {#{value_id => VId},
                     St#st{values = Values#{Etf => VId}, value_bytes = Bytes + Size}}
            end
    end.

%% The value an env or config write set (the classifier's value_etf) is
%% stored like a value a read returned (stored/2): written once, named by
%% value_id, under the same budget. A read that returns the value the write
%% set names the same id. Only for an event that will be written: past the
%% user-event cap user_event/3 drops the event unwritten, and its value with
%% it: no value line, no budget spent.
written_value(Arg, #st{user = U, max_user = Max} = St) when U >= Max -> {Arg, St};
written_value(#{value_etf := Etf} = Arg, St) when is_binary(Etf) ->
    {Ref, St1} = stored(Etf, St),
    {maps:merge(maps:remove(value_etf, Arg), Ref), St1};
written_value(Arg, St) -> {Arg, St}.

%% A line that follows a traced call one to one (a `returned` line): counted
%% as a call (check_limits/1, the queue check), not as a user event, so it
%% does not take from the read budget max_user gives the events themselves.
counted_line(_Line, #st{overflow = true} = St) -> St;
counted_line(Line, #st{calls = Calls} = St0) ->
    case check_limits(St0#st{calls = Calls + 1}) of
        #st{overflow = true} = St -> St;
        St ->
            write(St, Line),
            St
    end.

put_frames(Pid, [], Returns) -> maps:remove(Pid, Returns);
put_frames(Pid, Frames, Returns) -> Returns#{Pid => Frames}.

%% The event of a return-traced call carries the id its `returned` line
%% will name; the call's own frame (pushed by pending/5) remembers it.
hold(Pid, M, F, Args, Id, Line, #st{returns = Returns} = St) ->
    case {ncc_tracer_channels:returned_mfa(M, F, length(Args)), maps:get(Pid, Returns, [])} of
        {true, [skip | Rest]} ->
            {Line#{call_id => Id}, St#st{returns = Returns#{Pid => [{call, Id, Args} | Rest]}}};
        _ ->
            {Line, St}
    end.

%% Messages from two traced processes reach the collector in any order. A
%% child's own `spawned` message comes before its own events, but its
%% parent's `spawn` message (which, with the parent's spawn call before it,
%% decides the child's lineage) can come later. Before judging a process
%% the collector has no lineage for, it takes the parent's messages, in
%% order, until that one; if it never comes the process stays unknown,
%% which is user.
lineage(Pid, #st{procs = Procs, initial = Initial, parents = Parents} = St) ->
    case {is_map_key(Pid, Procs) orelse is_map_key(Pid, Initial), Parents} of
        {true, _} -> St;
        {false, #{Pid := Parent}} ->
            await_parent(Pid, Parent, St#st{parents = maps:remove(Pid, Parents)},
                         erlang:monotonic_time(millisecond)
                             + env_int("NCC_TRACE_LINEAGE_TIMEOUT_MS", 5000));
        {false, _} -> St
    end.

await_parent(Child, Parent, St, Deadline) ->
    case is_map_key(Child, St#st.procs) of
        true -> St;
        false ->
            Left = max(Deadline - erlang:monotonic_time(millisecond), 0),
            receive
                {trace_ts, Parent, _, _, _} = Msg ->
                    await_parent(Child, Parent, collected(traced(Msg, St)), Deadline);
                {trace_ts, Parent, _, _, _, _} = Msg ->
                    await_parent(Child, Parent, collected(traced(Msg, St)), Deadline)
            after Left -> St
            end
    end.

continue({finish, _, _, _}, _St) -> ok;
continue(_Req, St) -> loop(St).

%% A request without the driver's token: rejected, written as an integrity
%% event (bounded, capped_line/2), and every later check fails.
forged(From, Ref, Req, St) ->
    ok = reject(From, Ref),
    Arg = #{request => ncc_tracer_channels:term_bin(request_name(Req))},
    Line = #{kind => event, ts => now_ns(), pid => ncc_tracer_channels:term_bin(From),
             channel => integrity, mfa => <<"ncc_tracer:forged_request">>, arg => Arg,
             extent => unjudged, first => null, user => null, first_kind => <<"none">>},
    capped_line(Line, St#st{tampered = true, unjudged = St#st.unjudged + 1}).

%% A line a package can make the collector write at will, counted as a call
%% (check_limits/1) and as a user event: past either cap the trace overflows
%% once and nothing more is written.
capped_line(_Line, #st{overflow = true} = St) -> St;
capped_line(Line, #st{calls = Calls} = St0) ->
    case check_limits(St0#st{calls = Calls + 1}) of
        #st{overflow = true} = St -> St;
        #st{user = U, max_user = Max} = St when U >= Max -> overflow(St, <<"user_events">>);
        St ->
            write(St, Line),
            St#st{user = St#st.user + 1}
    end.

reject(From, Ref) when is_pid(From) ->
    From ! {Ref, {error, unauthorized}},
    ok;
reject(_From, _Ref) -> ok.

request_name(Req) when is_tuple(Req), tuple_size(Req) > 0 -> element(1, Req);
request_name(Req) -> Req.

call_event(_Pid, _M, _F, _Args, _Stack, _Ts, #st{overflow = true} = St) -> St;
call_event(Pid, M, F, Args, Stack, Ts, #st{calls = Calls} = St0) ->
    case check_limits(St0#st{calls = Calls + 1}) of
        #st{overflow = true} = St -> St;
        St2 ->
            St1 = lineage(Pid, St2),
            St = depth_seen(M, F, Args, St1),
            Extent = safe_extent(Stack, St#st.depth, fun toolchain/1, user_process(Pid, St),
                                 is_script(Pid)),
            %% The call's id is its own count, taken here once.
            Info = {Pid, M, F, Args, Ts, {caller(Stack), bottom(Stack, St#st.depth)}, Calls + 1},
            classified(M, F, Args, Extent, Info, Stack, St)
    end.

classified(erlang, F, _Args, Extent, {Pid, _, _, _, _, _, _}, _Stack, St)
  when F =:= spawn; F =:= spawn_link; F =:= spawn_monitor; F =:= spawn_opt;
       F =:= spawn_request ->
    spawn_call(Pid, Extent, St);
classified(_M, _F, _Args, toolchain, _Info, _Stack, St) -> St;
classified(M, F, Args, {user, _, _, _} = Extent, Info, Stack, St) ->
    case M =:= elixir_compiler orelse ncc_tracer_channels:checker_module(M) of
        true -> toolchain_entry(M, F, Args, Extent, Info, Stack, St);
        false ->
            case {ncc_tracer_channels:mix_state(M, F, length(Args)),
                  ncc_tracer_channels:mix_entry(M)} of
                {true, _} -> mix_state_entry(M, F, Args, Extent, Info, Stack, St);
                {false, true} -> mix_entry(M, F, Args, Extent, Info, Stack, St);
                {false, false} ->
                    Class = rebar_script(code_load(probed(channel(M, F, Args, St), Stack),
                                                   M, F, Args, Stack), M, F, Args, Stack),
                    record(Class, Extent, Info, St)
            end
    end.

%% OTP's own code loading (precompiled judge refinements, item 5a): a read
%% erl_prim_loader makes while code:ensure_loaded/1 loads a module into the
%% calling process, judged on the full stack (before frames/4 cuts it) and
%% only under the pinned shape that makes that read
%% (ncc_tracer_stack:code_loading_read/4). Only a flag: the judge decides
%% (NccWorker.Portability.Events). The stack is looked at only for the two
%% calls that can be one; a stack this cannot take apart sets no flag. The
%% os_type branch is deliberate defence in depth: a real pathtype os_type
%% read is already path handling (erl_prim_loader:pathtype/1 is a path
%% frame, so record/4 counts it), and only read_link depends on the flag.
code_load({Channel, Arg} = Class, M, F, Args, Stack)
  when (M =:= erlang andalso F =:= system_info andalso Args =:= [os_type]);
       (M =:= prim_file andalso F =:= read_link) ->
    case (try ncc_tracer_stack:code_loading_read(M, F, Args, Stack) catch _:_ -> false end) of
        true when is_map(Arg) -> {Channel, Arg#{code_loading => true}};
        _ -> Class
    end;
code_load(Class, _M, _F, _Args, _Stack) -> Class.

%% The plain arguments read by the code of a rebar.config.script Mix
%% evaluates (ncc_tracer_stack:rebar_script_read/2), judged on the full stack
%% (before frames/4 cuts it): only a flag, which differential builds take
%% (NccWorker.Portability.Events). A stack this cannot take apart sets none.
rebar_script({Channel, Arg} = Class, init, get_plain_arguments, [], Stack) when is_map(Arg) ->
    case (try ncc_tracer_stack:rebar_script_read(Stack, fun toolchain/1) catch _:_ -> false end) of
        true -> {Channel, Arg#{rebar_script => true}};
        false -> Class
    end;
rebar_script(Class, _M, _F, _Args, _Stack) -> Class.

%% A read of Mix state (ncc_tracer_channels mix_state/3) marks only when Mix
%% did not make it. A target read is Mix's only when one of the Mix
%% functions that read it for Mix's own work made it
%% (ncc_tracer_stack:target_read_by_mix/2); a build path read when Mix made
%% it and no dispatcher or fun-calling helper is on top
%% (ncc_tracer_stack:made_by_mix_strict/2). A lookup by table id is first
%% resolved to Mix.State's name (mix_state_args/2).
mix_state_entry(M, F, Args0, Extent, Info0, Stack, St) ->
    Args = mix_state_args(M, Args0),
    Info = setelement(4, Info0, Args),
    Class = channel(M, F, Args, St),
    case (try made_by_mix(Class, Stack) catch _:_ -> false end) of
        true -> St;
        false -> record(probed(Class, Stack), Extent, Info, St)
    end.

made_by_mix({mix_state, #{'fun' := <<"target">>}}, Stack) ->
    ncc_tracer_stack:target_read_by_mix(Stack, fun toolchain/1);
made_by_mix(_Class, Stack) -> ncc_tracer_stack:made_by_mix_strict(Stack, fun toolchain/1).

%% ets:lookup/2 and lookup_element/3,4 by table id: only a lookup of the
%% target key reaches here (the match spec's head), and only Mix.State's
%% table is named for the classifier; any other table stays an id, which
%% classifies as nothing.
mix_state_args(ets, [Tid | Rest]) when is_reference(Tid) ->
    case (try ets:info(Tid, name) catch _:_ -> undefined end) of
        'Elixir.Mix.State' -> ['Elixir.Mix.State' | Rest];
        _ -> [Tid | Rest]
    end;
mix_state_args(_M, Args) -> Args.

%% A call into Mix's compile entry points marks its window only when Mix
%% did not make it (ncc_tracer_stack:made_by_mix/2).
mix_entry(M, F, Args, Extent, Info, Stack, St) ->
    case (try ncc_tracer_stack:made_by_mix(Stack, fun toolchain/1) catch _:_ -> false end) of
        true -> St;
        false -> record(probed(channel(M, F, Args, St), Stack), Extent, Info, St)
    end.

%% A call into the type checker or the compiler's entry points marks its
%% window only when package code made it: the compiler makes such calls for
%% every module it compiles (ncc_tracer_stack:made_by_toolchain/2), so those
%% are not even written.
toolchain_entry(M, F, Args, Extent, Info, Stack, St) ->
    case (try ncc_tracer_stack:made_by_toolchain(Stack, fun toolchain/1) catch _:_ -> false end) of
        true -> St;
        false -> record(probed(channel(M, F, Args, St), Stack), Extent, Info, St)
    end.

%% A package can lower backtrace_depth (phoenix's start/2 sets it). Stacks
%% are cut at the live value, so they are judged against the lowest value
%% set since the last check: messages from different processes arrive in
%% any order, so a raise seen first must not make an earlier cut stack look
%% complete. Only a check (after every message is delivered) restores it,
%% and it reports the window even when the flag was put back meanwhile.
depth_seen(erlang, system_flag, [backtrace_depth, N], #st{set_depth = Set} = St)
  when is_integer(N), N >= 0 ->
    Live = min(N, Set),
    St#st{depth = min(St#st.depth, Live), lowered = St#st.lowered orelse Live < Set};
depth_seen(_M, _F, _Args, St) -> St.

%% Set it back (system_info has no backtrace_depth key, so reading it means
%% setting it) and report whether it held since the last window close. A
%% sentinel checks too but keeps what it found for the close, which is the
%% check the judge reads for the window.
depth_check(#st{set_depth = Set, lowered = Lowered} = St, When) ->
    Ok = erlang:system_flag(backtrace_depth, Set) =:= Set andalso not Lowered,
    {Ok, St#st{depth = Set, lowered = When =/= close andalso not Ok}}.

channel(M, F, Args, St) ->
    case app_call(M, F, Args) of
        false -> classified_channel(M, F, Args, St);
        Call -> Call
    end.

classified_channel(M, F, Args, St) ->
    try ncc_tracer_channels:classify(M, F, Args) of
        unknown -> native_channel(M, F, Args, St);
        {Channel, Summary} when is_atom(Channel), is_map(Summary) -> {Channel, Summary};
        _Other -> {unclassified, #{}}
    catch
        _:_ -> {unclassified, #{}}
    end.

%% Any call into a natively built closure dependency's modules (spec R3),
%% except the introspection the Elixir compiler itself makes while it expands
%% a call to such a module (`__info__(:macros)` and friends): that returns
%% compile metadata, not a value the native build produced.
native_channel(M, F, Args, St) ->
    Introspection = lists:member(F, ?INTROSPECTION),
    case {is_map_key(M, St#st.native), is_map_key(M, St#st.holders)} of
        {true, _} when not Introspection -> {native_closure, #{module => atom_to_binary(M)}};
        {_, true} when not Introspection -> {root_holder, #{module => atom_to_binary(M)}};
        {_, true} ->
            case relocated_info(F, Args) of
                true -> {root_holder, #{module => atom_to_binary(M)}};
                false -> unknown
            end;
        _ -> unknown
    end.

%% A holder's own introspection that hands over what its relocation changes
%% (S4): its md5, its attributes (the default vsn is the md5, and a
%% persisted attribute may hold the path) and its compile info. The Elixir
%% compiler's own `__info__(macros)` and friends, which it makes while it
%% expands a call to the holder, are not among them.
relocated_info(module_info, []) -> true;
relocated_info(module_info, [K]) -> lists:member(K, [md5, attributes, compile]);
relocated_info('__info__', [K]) -> lists:member(K, [md5, attributes, compile]);
relocated_info(_F, _Args) -> false.

record(_Class, toolchain, _Info, St) -> St;
record(unknown, {user, unjudged, _, _}, _Info, St) -> St#st{unjudged = St#st.unjudged + 1};
record(unknown, _Extent, _Info, St) -> St;
record({env, #{name := <<?SENTINEL, App0/binary>>}}, {user, _, _, {?PROBE, _, _, _}},
       {Pid, _, _, _, Ts, _, _}, St0) ->
    %% Which sentinel this is comes from the state before the checks: only
    %% the final one (the driver's pid with its nonce) may accept Mix's
    %% consolidated-protocol reload, so checks/2 must be told it is final
    %% before it runs. Neither field it reads (final_pid, final_nonce) is
    %% changed by the checks.
    {App, Final} = sentinel_app(App0, Pid, St0),
    {Checks, St} = checks(St0, case Final of
                                   true -> final;
                                   false -> sentinel
                               end),
    write(St, Checks#{kind => sentinel, app => App, ts => Ts, pid => pid_bin(Pid)}),
    St#st{final = St#st.final orelse Final};
record({Channel, Arg} = Class, {user, Kind, First, _} = Extent, {_, M, F, _, _, _, _} = Info, St) ->
    case {path_os_read(Channel, M, F, Arg, Kind, First), quiet_probe(Class, Kind, First, M, F)} of
        {true, _} -> St#st{path_os_reads = St#st.path_os_reads + 1};
        {false, drop} -> St#st{dropped_probes = St#st.dropped_probes + 1};
        {false, compact} -> compact_line(Class, Extent, Info, St);
        {false, write} -> user_line(Class, Extent, Info, St)
    end.

%% Only the first compact code:ensure_loaded/1 of a module per process and
%% window: `ensured` takes the earliest (NccWorker.Portability.Probes); the
%% set is emptied at every window boundary.
compact_line({probe, #{module := Module}} = Class, Extent, {Pid, _, _, _, _, _, _} = Info,
             #st{ensured_seen = Seen} = St) ->
    case is_map_key({Pid, Module}, Seen) of
        true -> St#st{dropped_probes = St#st.dropped_probes + 1};
        false ->
            user_line(Class, Extent, Info,
                      St#st{compact = true, ensured_seen = Seen#{{Pid, Module} => true}})
    end.

%% A probe the judge ignores whatever else the trace holds
%% (NccWorker.Portability.Probes), as the toolchain's own lookups are: the
%% compiler, Elixir and Mix make them by the ten thousand, and a line each
%% took a trace to five times its size (round 2, R1-E). Never one on a
%% stack the tracer could not judge. `drop`: the code server's own probe
%% inside a traced probe, or a probe the toolchain made (not `by_package`)
%% of a module we did not load and that is no installed application's off
%% every compile's path. `compact`: such a code:ensure_loaded/1, which the
%% judge reads for `ensured` (by pid, time and module), written without its
%% frames. Anything else is written whole.
quiet_probe({probe, Arg}, Kind, First, M, F) when Kind =/= unjudged ->
    Mfa = {M, F},
    case nested_probe(First) of
        true -> drop;
        false ->
            Toolchain = maps:get(by_package, Arg, true) =:= false
                andalso maps:get(app, Arg, null) =:= null
                andalso every_path_or_none(maps:get(otp_app, Arg, null)),
            case {Toolchain, Mfa} of
                {false, _} -> write;
                {true, {code, ensure_loaded}} -> compact;
                {true, _} -> drop
            end
    end;
quiet_probe(_Class, _Kind, _First, _M, _F) -> write.

every_path_or_none(null) -> true;
every_path_or_none(App) -> lists:member(App, ?ON_EVERY_PATH).

%% A compact line keeps its user frame only when that is a mix.exs (the
%% judge attributes such an event to the dependency it belongs to).
mix_exs_frame(#{file := File} = User) when is_binary(File) ->
    case filename:basename(File) of
        <<"mix.exs">> -> User;
        _ -> null
    end;
mix_exs_frame(_User) -> null.

%% The code server's own probe inside a traced one (its first frame is a
%% probe function of `code`), which the judge always ignores.
nested_probe({code, F, _A, _Location}) ->
    lists:member(F, [ensure_loaded, is_loaded, which, module_status, get_object_code,
                     load_file, where_is_file]);
nested_probe(_First) -> false.

%% The OS family a path function reads to know its separators (os:type/0
%% under filename:split/1, Path.join/2, ...): the judge ignores such a read
%% wherever it falls (NccWorker.Portability.Events, path handling), so it is
%% only counted, never written. A compile that joins paths in a user
%% process reads it hundreds of thousands of times, and a line each would
%% outgrow the report's read budget (ash). Only a stack the tracer judged
%% (not unjudged) whose first frame past the wrappers renders and is one of
%% the path internals (ncc_tracer_channels:path_os_frames/0); a frame that
%% does not render is written, and frames/4 makes it unjudged.
path_os_read(os_identity, M, F, Arg, Kind, First) when Kind =/= unjudged ->
    ncc_tracer_channels:path_os_read(M, F, Arg) andalso path_frame(First);
path_os_read(_Channel, _M, _F, _Arg, _Kind, _First) -> false.

path_frame(First) ->
    try ncc_tracer_stack:frame(First) of
        #{module := M, function := F, arity := A} -> ncc_tracer_channels:path_os_frame(M, F, A);
        _ -> false
    catch _:_ -> false
    end.

user_line({Channel, Arg0}, {user, Kind0, First0, User0}, {Pid, M, F, Args, Ts, Ends, Id},
          #st{compact = true} = St0) ->
    {Kind, _First, User, _Ends} = frames(Kind0, First0, User0, Ends),
    {Arg, St1} = written_value(Arg0, St0#st{compact = false}),
    Line0 = #{kind => event, ts => Ts, pid => pid_bin(Pid), channel => Channel,
              mfa => ncc_tracer_stack:mfa_bin(M, F, length(Args)),
              arg => enrich(Channel, Arg), extent => Kind, user => mix_exs_frame(User)},
    {Line, St} = hold(Pid, M, F, Args, Id, Line0, St1),
    user_event(Line, Kind =:= unjudged orelse Channel =:= unclassified, St);
user_line({Channel, Arg0}, {user, Kind0, First0, User0}, {Pid, M, F, Args, Ts, Ends, Id}, St0) ->
    {Kind, First, User, {Caller, Bottom}} = frames(Kind0, First0, User0, Ends),
    {Arg, St1} = written_value(Arg0, St0),
    Line0 = #{kind => event, ts => Ts, pid => pid_bin(Pid), channel => Channel,
              mfa => ncc_tracer_stack:mfa_bin(M, F, length(Args)),
              arg => enrich(Channel, Arg), extent => Kind, first => First, user => User,
              caller => Caller, caller_kind => caller_kind(Ends),
              bottom => Bottom, first_kind => first_kind(First0)},
    {Line, St} = hold(Pid, M, F, Args, Id, Line0, St1),
    user_event(Line, Kind =:= unjudged orelse Channel =:= unclassified, St).

sentinel_app(<<"__final__:", Nonce/binary>>, Pid, #st{final_pid = Pid, final_nonce = Nonce}) ->
    {<<"__final__">>, true};
sentinel_app(<<"__final__", _/binary>>, _Pid, _St) -> {<<"__final__">>, false};
sentinel_app(App, _Pid, _St) -> {App, false}.

%% The checks every sentinel, window close and finish makes: backtrace_depth
%% held and every pattern is still set.
checks(St0, When) ->
    {DepthOk, St1} = depth_check(St0, When),
    {PatternsOk, St} = patterns_check(St1, When),
    {#{depth_ok => DepthOk,
       integrity_ok => PatternsOk andalso not St#st.tampered andalso get(code_swap) =:= undefined},
     St}.

%% A close or finish also needs every trace message delivered first.
closing_checks(St0, Delivered) ->
    {#{integrity_ok := Ok} = Checks, St} = checks(St0, close),
    {Checks#{integrity_ok := Ok andalso Delivered, delivered => Delivered}, St}.

%% A frame the renderer cannot take apart turns the event unjudged, with no
%% frames, rather than crashing the collector or dropping the event.
frames(Kind, First, User, {Caller, Bottom}) ->
    try {Kind, ncc_tracer_stack:frame(First), ncc_tracer_stack:frame(User),
         {ncc_tracer_stack:frame(Caller), ncc_tracer_stack:frame(Bottom)}}
    catch _:_ -> {unjudged, null, null, {null, null}}
    end.

%% A frame the classifier cannot take apart is `none`: the judge then treats
%% the read as the package's own (fail closed).
first_kind(First) ->
    try ncc_tracer_stack:first_kind(First, fun toolchain/1)
    catch _:_ -> <<"none">>
    end.

%% Whether the frame right below the traced call is the toolchain's loaded
%% code (`toolchain`), anything else (`user`), or no frame (`none`): the
%% judge narrows an os:type/0 read to the family only when the toolchain's
%% own File.rm_rf/1 made it, never a package's module of that name.
caller_kind({{M, _F, _A, _Location}, _Bottom}) when is_atom(M) ->
    try toolchain(M) of
        true -> <<"toolchain">>;
        false -> <<"user">>
    catch _:_ -> <<"none">>
    end;
caller_kind(_Ends) -> <<"none">>.

%% The frame right below the traced call, before any wrapper is stripped:
%% the judge exempts one OTP-internal caller (erlang:big_binary_to_int/2).
caller([Frame | _]) -> Frame;
caller(_Stack) -> none.

%% The process's bottom-most frame, where it started (the judge recognises
%% an epp server by it), only when the stack was seen whole: a stack as
%% deep as the live backtrace_depth may have lost its bottom.
bottom(Stack, Depth) when is_list(Stack), Stack =/= [], length(Stack) < Depth ->
    lists:last(Stack);
bottom(_Stack, _Depth) -> none.

user_event(_Line, _Unjudged, #st{user = U, max_user = Max} = St) when U >= Max ->
    overflow(St, <<"user_events">>);
user_event(#{extent := Kind} = Line, Unjudged, #st{user = U, truncated = T} = St) ->
    write(St, Line),
    St#st{user = U + 1, truncated = T + count(Kind =:= truncated),
          unjudged = St#st.unjudged + count(Unjudged)}.

count(true) -> 1;
count(false) -> 0.

%% An install-location read of an OTP or Elixir app is allowed (spec R1);
%% the collector, which is not traced, looks the app up.
enrich(install, #{app := App} = Arg) when is_atom(App) ->
    Arg#{app := atom_to_binary(App), toolchain_app => toolchain_app(App)};
enrich(install, #{app := App} = Arg) ->
    Arg#{app := ncc_tracer_channels:term_bin(App), toolchain_app => false};
enrich(_Channel, Arg) -> Arg.

%% By the directory's real path, against the installs' real paths.
toolchain_app(App) ->
    case code:lib_dir(App) of
        Dir when is_list(Dir) ->
            try under_any(abs_realpath(Dir), get(install_roots)) catch _:_ -> false end;
        _ -> false
    end.

%% --- lineage -----------------------------------------------------------------

%% The spawn call fires in the parent before the child exists; the parent's
%% own `spawn` message that follows it names the child.
spawn_call(_Pid, toolchain, St) -> St;
spawn_call(Pid, {user, _, _, _}, St) -> St#st{spawning = maps:put(Pid, true, St#st.spawning)}.

%% A process is a user process when its parent is, when its parent spawned
%% it from user extent, or when its start MFA or a fun in its arguments (six
%% levels deep) belongs to a non-toolchain module. A child whose parent's
%% `spawn` message has not been seen yet is unknown, which is user.
spawned(Child, Parent, MFA, St0) ->
    St = lineage(Parent, St0),
    User = user_process(Parent, St) orelse maps:get(Parent, St#st.spawning, false)
        orelse mfa_user(MFA),
    St#st{procs = maps:put(Child, User, St#st.procs),
          spawning = maps:remove(Parent, St#st.spawning), spawned = St#st.spawned + 1}.

user_process(Pid, #st{procs = Procs, initial = Initial}) ->
    case Procs of
        #{Pid := User} -> User;
        _ -> not is_map_key(Pid, Initial)
    end.

mfa_user(MFA) ->
    try mfa_refs_user(MFA)
    catch _:_ -> true
    end.

mfa_refs_user({M, _F, Args}) when is_atom(M) -> (not toolchain(M)) orelse refs_user(Args, 6);
mfa_refs_user(_MFA) -> true.

refs_user(_Term, 0) -> false;
refs_user(Fun, _Depth) when is_function(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    not toolchain(M);
refs_user(Tuple, Depth) when is_tuple(Tuple), tuple_size(Tuple) =< 32 ->
    refs_user(tuple_to_list(Tuple), Depth - 1);
refs_user(List, Depth) when is_list(List) -> list_refs(List, Depth - 1, 32);
refs_user(_Term, _Depth) -> false.

list_refs(_List, _Depth, 0) -> false;
list_refs([H | T], Depth, N) -> refs_user(H, Depth) orelse list_refs(T, Depth, N - 1);
list_refs([], _Depth, _N) -> false;
list_refs(Tail, Depth, _N) -> refs_user(Tail, Depth).

%% --- child compiles ------------------------------------------------------------

compiled(Pid, Result, Ts, St) ->
    {Src, OutDir} = maps:get(Pid, St#st.sources, {null, null}),
    Source = ncc_tracer_channels:chars(Src),
    write(St, #{kind => compile, ts => Ts, source => Source,
                result => compile_result(Result), module => compile_module(Result),
                beam_sha256 => beam_sha256(OutDir, Result)}),
    libs_line(St#st{sources = maps:remove(Pid, St#st.sources)}).

%% The output dir compile:file/2 was given ({outdir, Dir}, as rebar3 passes
%% it), or null.
outdir([Opts | _]) when is_list(Opts) ->
    case lists:keyfind(outdir, 1, Opts) of
        {outdir, Dir} when is_list(Dir); is_binary(Dir) -> Dir;
        _ -> null
    end;
outdir(_Rest) -> null.

%% The sha256 of the beam a compile wrote, read by this untraced collector
%% when the compile's return reaches it, so the judge can hold the beam on
%% disk to it: one written over later is not the traced compile's (review
%% S5 R1). null when the module, the dir or the file cannot be read.
-define(MAX_BEAM_BYTES, 67108864).
beam_sha256(OutDir, Result) when OutDir =/= null, is_tuple(Result),
                                 element(1, Result) =:= ok, tuple_size(Result) >= 2,
                                 is_atom(element(2, Result)) ->
    Path = filename:join(OutDir, atom_to_list(element(2, Result)) ++ ".beam"),
    try
        case file:read_file_info(Path) of
            {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_BEAM_BYTES ->
                {ok, Bytes} = file:read_file(Path),
                binary:encode_hex(crypto:hash(sha256, Bytes), lowercase);
            _ ->
                null
        end
    catch _:_ -> null
    end;
beam_sha256(_OutDir, _Result) -> null.

%% A child VM has no end line (rebar3 halts): it writes its mapped
%% libraries after every compile and flush, whenever they changed, and once
%% after the first compile whatever they are.
libs_line(#st{libs = Last, libs_written = Written} = St) ->
    case mapped_libs() of
        Last when Written -> St;
        Libs ->
            write(St, (libs_fields(Libs))#{kind => libs, ts => now_ns()}),
            St#st{libs = Libs, libs_written = true}
    end.

%% --- mapped libraries -----------------------------------------------------------

%% erlang:load_nif/2 is not call-traceable (OTP 28, 29), so what a compile
%% loads natively is read from the VM's memory map instead. The OTP NIFs a
%% compile normally pulls in are loaded before the start snapshot, so they
%% and the system libraries they map are part of it.
start_libs() ->
    lists:foreach(fun(M) -> quietly(fun() -> code:ensure_loaded(M) end) end,
                  [crypto, asn1rt_nif]),
    mapped_libs().

mapped_libs() ->
    case file:read_file("/proc/self/maps") of
        {ok, Maps} -> maps_libs(Maps);
        {error, _} -> unavailable
    end.

%% The path of every file-backed mapping (inode not 0), each once, sorted.
%% Not only `.so` names: the map shows the file a link resolved to, so a
%% NIF loaded through `x.so -> payload` maps as `payload`. A file-backed
%% line whose path cannot be read (or a line that does not parse) makes the
%% whole snapshot unavailable.
maps_libs(Maps) ->
    Lines = binary:split(Maps, <<"\n">>, [global, trim_all]),
    try {ok, lists:usort(lists:append([maps_file(Line) || Line <- Lines]))}
    catch throw:unparsable -> unavailable
    end.

%% Fields: address, perms, offset, device, inode, then the path, which may
%% itself contain blanks.
maps_file(Line) ->
    case re:run(Line, <<"^\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+(\\d+)(?:\\s+(.*))?$">>,
                [{capture, all_but_first, binary}]) of
        {match, [<<"0">> | _]} -> [];
        {match, [_Inode, <<"/", _/binary>> = Path]} -> [Path];
        _ -> throw(unparsable)
    end.

libs_fields({ok, Libs}) -> #{nif_check => ok, mapped_libs => Libs};
libs_fields(unavailable) -> #{nif_check => unavailable, mapped_libs => null}.

compile_result(Result) when is_tuple(Result), element(1, Result) =:= ok -> ok;
compile_result(_Result) -> error.

compile_module(Result) when is_tuple(Result), element(1, Result) =:= ok,
                            tuple_size(Result) >= 2, is_atom(element(2, Result)) ->
    atom_to_binary(element(2, Result));
compile_module(_Result) -> null.

%% --- requests ----------------------------------------------------------------

request({window_open, App, Ts}, _From, St) ->
    write(St, #{kind => window_open, app => App, ts => Ts}),
    {ok, St#st{ensured_seen = #{}}};
request({window_close, App, Ts, Delivered}, _From, St0) ->
    {Checks, St1} = closing_checks(St0, Delivered),
    %% Every trace message of the window is handled by now (closing_checks/2
    %% waits for their delivery): a later compact line is another window's.
    St = St1#st{ensured_seen = #{}},
    write(St, (maps:merge(Checks, libs_fields(mapped_libs())))#{kind => window_close, app => App,
                                                                ts => Ts}),
    {ok, St};
request({closure, Packages, Deps}, _From, St) ->
    write(St, #{kind => closure, packages => Packages, deps => Deps, ts => now_ns()}),
    {ok, St};
request({built, App, Dir}, _From, St) ->
    Fields = built_fields(ncc_tracer_digest, Dir),
    write(St, Fields#{kind => built, app => App, ts => now_ns()}),
    {ok, holder_patterns(App, Dir, St)};
request({sweep, _App}, _From, #st{sweep = off} = St) -> {ok, St};
request({sweep, App}, _From, #st{sweep = {on, Expected}} = St) ->
    Result = try ncc_tracer_sweep:sweep(Expected)
             catch _:_ -> {unavailable, <<"the sweep failed">>}
             end,
    write(St, (sweep_fields(Result))#{kind => sweep, app => App, ts => now_ns()}),
    case Result of
        {ok, _Killed} -> {ok, St};
        _ -> {{error, sweep_failed}, St}
    end;
request({native, App, Ebin}, _From, St) -> {ok, native(App, Ebin, St)};
request({holders, Holders}, _From, St) ->
    Wanted = lists:foldl(fun({App, M}, Acc) ->
                                 maps:update_with(bin(App), fun(Ms) -> [M | Ms] end, [M], Acc)
                         end, #{}, Holders),
    {ok, St#st{holders_wanted = Wanted}};
request({consolidated, Dir}, _From, St) -> {ok, St#st{consolidated = Dir}};
request({config_env, Entries, Truncated}, _From, St) ->
    write(St, #{kind => config_env, entries => Entries, truncated => Truncated, ts => now_ns()}),
    {ok, St};
request(config_env_error, _From, St) ->
    write(St, #{kind => config_env, error => true, ts => now_ns()}),
    {ok, St};
request(final_nonce, From, St) ->
    Nonce = random_hex(),
    {Nonce, St#st{final_pid = From, final_nonce = Nonce}};
request({finish, Status, Ts, Delivered}, _From, St) ->
    {finish_trace(Status, Ts, Delivered, St), St};
request(flush, _From, St) -> {ok, libs_line(St)};
request(_Req, _From, St) -> {{error, unknown_request}, St}.

%% Read once, in the collector's init: what a package's code does to the env
%% later cannot turn the sweep off. Child VMs (rebar3) never sweep: they run
%% inside a window of the Mix VM's, which sweeps when it closes.
sweep_setting(main) ->
    case os:getenv("NCC_TRACE_SWEEP") of
        V when V =:= false; V =:= "" -> off;
        Start -> {on, Start}
    end;
sweep_setting(child) -> off.

sweep_fields({ok, Killed}) -> #{result => ok, killed => procs_json(Killed)};
sweep_fields({survivors, Left, Killed}) ->
    #{result => survivors, survivors => procs_json(Left), killed => procs_json(Killed)};
sweep_fields({unavailable, Why}) -> #{result => unavailable, why => Why};
sweep_fields(_Other) -> #{result => unavailable, why => <<"unexpected sweep result">>}.

procs_json(Procs) ->
    [#{pid => Pid, comm => comm_text(Comm)} || #{pid := Pid, comm := Comm} <- Procs].

%% A command name is whatever bytes a process set, which JSON cannot always
%% carry as text.
comm_text(Comm) ->
    case unicode:characters_to_binary(Comm) of
        Text when is_binary(Text) -> Text;
        _ -> <<"hex:", (binary:encode_hex(Comm))/binary>>
    end.

%% The built line's digest fields, by Mod:dir/1 (ncc_tracer_digest). It
%% never raises, but a digest module that is not loaded must cost one
%% dependency its digest, not the collector.
built_fields(Mod, Dir) ->
    try Mod:dir(Dir) of
        {ok, Hex, Files} -> #{digest => Hex, files => Files};
        {error, Why} -> #{digest => null, error => reason_bin(Why)}
    catch _:_ -> #{digest => null, error => <<"digest_unavailable">>}
    end.

%% Spec R3 native taint: call patterns on every module of a natively built
%% closure dependency, set before any later dependency compiles. Loading them
%% can run on_load (a NIF load) in a traced process; those events fall inside
%% the quiet interval written around it, which the judge drops.
native(App, Ebin, #st{session = Session, set_depth = Depth} = St) ->
    write(St, #{kind => quiet_open, app => App, ts => now_ns()}),
    _ = case lists:member(Ebin, code:get_path()) of
            true -> true;
            false -> code:add_pathz(Ebin)
        end,
    Mods = [M || M <- beam_modules(Ebin), code:ensure_loaded(M) =:= {module, M}],
    Wanted = [wanted(Session, {M, '_', '_'}, match_spec(M, main, Depth)) || M <- Mods],
    Delivered = delivered(),
    write(St, #{kind => quiet_close, app => App, ts => now_ns(), delivered => Delivered =:= ok}),
    St#st{native = maps:merge(St#st.native, maps:from_keys(Mods, App)),
          wanted = St#st.wanted ++ Wanted}.

%% S4: call patterns on the holder modules the worker named for App, once
%% its window has closed, so a later window's call into one is an event
%% (channel root_holder). A holder that is not in App's ebin or does not
%% load cannot be patterned: the trace then fails its pattern check
%% (`unpatterned`), never a judgeable trace that missed its calls.
holder_patterns(App, Dir, #st{holders_wanted = Wanted} = St) when is_map_key(App, Wanted) ->
    #st{session = Session, set_depth = Depth} = St,
    Ebin = filename:join(to_list(Dir), "ebin"),
    write(St, #{kind => quiet_open, app => App, ts => now_ns()}),
    _ = case lists:member(Ebin, code:get_path()) of
            true -> true;
            false -> code:add_pathz(Ebin)
        end,
    Mods = maps:get(App, Wanted),
    Present = beam_modules(Ebin),
    Loaded = [M || M <- Mods, lists:member(M, Present), code:ensure_loaded(M) =:= {module, M}],
    Patterns = [wanted(Session, {M, '_', '_'}, match_spec(M, main, Depth)) || M <- Loaded],
    Delivered = delivered(),
    write(St, #{kind => quiet_close, app => App, ts => now_ns(), delivered => Delivered =:= ok}),
    St#st{holders = maps:merge(St#st.holders, maps:from_keys(Loaded, App)),
          wanted = St#st.wanted ++ Patterns,
          unpatterned = St#st.unpatterned orelse length(Loaded) =/= length(Mods)};
holder_patterns(_App, _Dir, St) -> St.

beam_modules(Ebin) ->
    [list_to_atom(filename:basename(F, ".beam")) || F <- filelib:wildcard("*.beam", Ebin)].

finish_trace(Status, Ts, Delivered, #st{fd = Fd, session = Session} = St1) ->
    St0 = case is_process_alive(St1#st.watcher) of
              true -> St1;
              false -> St1#st{tampered = true}
          end,
    {Checks, St} = closing_checks(St0, Delivered),
    write(St, #{kind => stats, calls => St#st.calls, user_events => St#st.user,
                truncated => St#st.truncated, unjudged => St#st.unjudged,
                spawned => St#st.spawned, path_os_reads => St#st.path_os_reads,
                dropped_probes => St#st.dropped_probes,
                pending_returns => lists:sum([length(Fs) || Fs <- maps:values(St#st.returns)])}),
    Late = [atom_to_binary(M) || M <- St#st.unloaded, erlang:module_loaded(M)],
    {InMemory, InMemoryOver} = in_memory(),
    write(St, (maps:merge(Checks, libs_fields(mapped_libs())))#{kind => 'end', ts => Ts,
                                                                status => Status,
                      final_sentinel => St#st.final, overflow => St#st.overflow,
                      late_loaded => Late, in_memory => InMemory,
                      in_memory_over => InMemoryOver}),
    ok = write_out(Fd),
    _ = file:close(Fd),
    _ = quietly(fun() -> trace:session_destroy(Session) end),
    ok.

%% S10 fix round 1: every module loaded now that no ebin dir holds, with the
%% source its compile names (`compile` info, else the file it was loaded
%% from): one a compile defined in memory (`code:which/1` is `[]`: a `.exs`
%% file a `mix.exs` or a module body loads, `Code.compile_string/2`,
%% `Module.create/3`) or loaded from a file outside an ebin. A dependency
%% compiled after it in the same VM can find it. Not the tracer's own, and
%% not a consolidated protocol (Mix's `consolidated` dir: the protocol's
%% own ebin holds it). The worker attributes each to the closure
%% application whose dir holds the source (`NccWorker.Portability`,
%% `defined_modules`). At most ?MAX_IN_MEMORY, else the second element is
%% true.
in_memory() ->
    Owned = tracer_owned(),
    Found = lists:sort([in_memory_item(M, W) || {M, W} <- code:all_loaded(),
                                                not lists:member(M, Owned), elsewhere(W)]),
    case length(Found) > ?MAX_IN_MEMORY of
        true -> {lists:sublist(Found, ?MAX_IN_MEMORY), true};
        false -> {Found, false}
    end.

elsewhere([]) -> true;
elsewhere(cover_compiled) -> true;
elsewhere(Path) when is_list(Path) ->
    not lists:member(filename:basename(filename:dirname(Path)), ["ebin", "consolidated"]);
elsewhere(_Other) -> false.

in_memory_item(M, Which) ->
    Source = try proplists:get_value(source, M:module_info(compile)) catch _:_ -> undefined end,
    #{module => atom_to_binary(M), source => source_bin(Source, Which)}.

source_bin(Source, _Which) when is_list(Source), Source =/= [] -> unicode:characters_to_binary(Source);
source_bin(_Source, Which) when is_list(Which), Which =/= [] -> unicode:characters_to_binary(Which);
source_bin(_Source, _Which) -> null.

check_limits(#st{calls = Calls, max_calls = Max} = St) when Calls > Max ->
    overflow(St, <<"calls">>);
check_limits(#st{calls = Calls} = St) when Calls band 4095 =:= 0 ->
    {message_queue_len, N} = process_info(self(), message_queue_len),
    case N > St#st.max_queue of
        true -> overflow(St, <<"queue">>);
        false -> St
    end;
check_limits(St) -> St.

overflow(#st{session = Session} = St, What) ->
    write(St, #{kind => overflow, what => What, ts => now_ns()}),
    _ = quietly(fun() -> trace:session_destroy(Session) end),
    St#st{overflow = true}.

%% --- the running mix script ---------------------------------------------------

%% `elixir -S mix` evaluates bin/mix as elixir_compiler_0, a module with no
%% object file, so its frame is on every stack of the Mix VM. The script is
%% the one Kernel.CLI ran: the name after -S in the VM's plain arguments,
%% looked up on PATH the way Kernel.CLI does (os:find_executable/1), taken to
%% its real path. Resolved once, before anything is traced; only a frame
%% whose file has exactly that real path is the toolchain's.
mix_script(child) -> none;
mix_script(main) ->
    try script_arg(init:get_plain_arguments()) of
        none -> none;
        Name ->
            case os:find_executable(Name) of
                false -> none;
                Path -> realpath(filename:absname(Path))
            end
    catch
        _:_ -> none
    end.

%% The first -S wins, as in Kernel.CLI: -S takes the next argument as the
%% script and leaves every argument after it to the script.
script_arg(["-S", Name | _]) -> Name;
script_arg([_ | Rest]) -> script_arg(Rest);
script_arg([]) -> none.

script_bin(none) -> null;
script_bin(Path) -> ncc_tracer_channels:chars(Path).

%% The mix script's frame is the toolchain's only in the process that ran
%% the script and called start_main/0 (the driver); a bin/mix-file frame in
%% any other process is a forged one (Code.compile_string(Src, <bin/mix>)).
is_script(Pid) ->
    case get(driver) of
        Pid -> fun script_file/1;
        _ -> fun(_File) -> false end
    end.

%% IsScript for the stack classifier: is this frame file the mix script?
%% Cached per file; a file that cannot be resolved is not the script.
script_file(File) ->
    case get(mix_script) of
        none -> false;
        Script ->
            case get({script_file, File}) of
                undefined ->
                    V = (try realpath(unicode:characters_to_list(File)) catch _:_ -> none end)
                        =:= Script,
                    put({script_file, File}, V),
                    V;
                V -> V
            end
    end.

%% Every symlink followed, `.` and `..` removed. At most 40 links.
realpath(Path) -> realpath(filename:split(filename:absname(Path)), [], 40).

realpath([], Acc, _Links) -> filename:join(lists:reverse(Acc));
realpath(_Parts, _Acc, 0) -> throw(too_many_links);
realpath(["." | Rest], Acc, Links) -> realpath(Rest, Acc, Links);
realpath([".." | Rest], [Root], Links) -> realpath(Rest, [Root], Links);
realpath([".." | Rest], [_ | Acc], Links) -> realpath(Rest, Acc, Links);
realpath([Part | Rest], Acc, Links) ->
    Here = filename:join(lists:reverse([Part | Acc])),
    case file:read_link_all(Here) of
        {ok, Target} ->
            Base = case filename:pathtype(Target) of
                       absolute -> [];
                       _ -> lists:reverse(Acc)
                   end,
            realpath(filename:split(filename:join(Base ++ [Target])) ++ Rest, [], Links - 1);
        {error, _} -> realpath(Rest, [Part | Acc], Links)
    end.

%% --- roots and toolchain modules -------------------------------------------

%% The directories whose code is the toolchain's: the OTP and Elixir
%% installs and MIX_HOME (Hex, rebar3, the archives), all read-only in the
%% worker image. Not HEX_HOME, which is per run and writable during the
%% compile and holds no code, and not the tracer's ebin, which lies in the
%% run dir: only the tracer's own modules from there are trusted, by the
%% md5 they had at start (owned_md5s/0). Each root is kept by its real
%% path, so is each module path it is compared with (object_verdict/5).
roots() ->
    Otp = [norm(code:root_dir())],
    Elixir = case code:lib_dir(elixir) of
                 Dir when is_list(Dir) -> [norm(filename:dirname(Dir))];
                 _ -> []
             end,
    put(install_roots, real_roots(Otp ++ Elixir)),
    real_roots(Otp ++ Elixir ++ [norm(mix_home())]).

real_roots(Roots) ->
    lists:usort([R || R0 <- Roots, R <- [R0, (try realpath(R0) catch _:_ -> R0 end)]]).

mix_home() ->
    case os:getenv("MIX_HOME") of
        V when V =:= false; V =:= "" -> filename:join(os:getenv("HOME", "/"), ".mix");
        V -> V
    end.

%% Taken at start, before any package code has run: the md5 of every
%% preloaded module and of every tracer module loaded (not the sentinel
%% probe, whose frames are user extent).
preloaded_md5s() ->
    maps:from_list([{M, Md5} || M <- erlang:pre_loaded(), Md5 <- [loaded_md5(M)],
                                Md5 =/= undefined]).

owned_md5s() ->
    maps:from_list([{M, Md5} || M <- tracer_owned(), M =/= ?PROBE, Md5 <- [loaded_md5(M)],
                                Md5 =/= undefined]).

%% The md5 of the code loaded for M now (erlang:get_module_info/2, a BIF:
%% never the module's own module_info/1), undefined when none is.
loaded_md5(M) ->
    try erlang:get_module_info(M, md5) catch _:_ -> undefined end.

%% Every module's kind is looked up by the code loaded for it now: the
%% verdict is kept with the md5 it was taken for, and one taken for other
%% code (a module redefined or reloaded since) is taken again.
toolchain(M) -> toolchain_module(M).

%% A module with no object file (elixir_compiler_N running a module body,
%% a module defined from a string, the sentinel probe) is not toolchain.
%% elixir_compiler_N never is, whatever code:which/1 finds: by the time the
%% collector looks, the body has usually been purged, and code:which/1 would
%% search the whole code path through the code server for a beam of that
%% name (one planted under a root would have passed).
toolchain_module(M) ->
    case ncc_tracer_stack:compiler_frame({M, none, 0, []}) of
        true -> false;
        false -> object_code_toolchain(M)
    end.

%% Old code is checked before the kept verdict: reloading the same binary
%% leaves the md5 as it was.
object_code_toolchain(M) ->
    Md5 = loaded_md5(M),
    case old_code(M) orelse cache_hit(get({tc, M}), Md5) of
        true -> false;
        {ok, V} -> V;
        miss ->
            V = object_verdict(M, (try code:which(M) catch _:_ -> undefined end), Md5,
                               verdict_env()),
            put({tc, M}, {Md5, V}),
            V andalso toolchain_code(M, Md5),
            V
    end.

%% --- code swaps --------------------------------------------------------------

%% A frame's kind is the verdict on the code loaded for its module when the
%% collector gets to the event, not when the call was made: a package can
%% call a forged module named like a toolchain one and load the toolchain's
%% code back before then, and the frame is taken for the toolchain's. Every
%% load is traced, its prepare (PREPARE_LOADING) and its finish
%% (FINISH_LOADING), and each module's versions kept with the first and last
%% time each was prepared or finished: code prepared before other code can
%% be finished after it, and only the finish makes it current. The
%% toolchain's code for a module (the md5s the verdict passed,
%% toolchain_code/2) prepared or finished again after other code of that
%% name fails every check from then on (code_swap): only then can a verdict
%% on the current code differ from the code a call ran. Either fact may come
%% first, in any order the messages arrive: each checks the other, and a
%% window's close sees every load made before it. Mix's protocol
%% consolidation loads other code after the toolchain's, never the
%% toolchain's after, and a package's module of a toolchain name that stays
%% loaded is never the toolchain's.
%% An on_load function runs code that is not current yet, and when it does
%% not return ok that code never is: a module's other code finished with an
%% on_load function to run fails the checks too once its toolchain code is
%% known, with no load of the toolchain's after (on_load_ran/2).
%% Returns what a finish of this prepare is a load of (code_finished/2).
code_prepared(M, Bin, Ts) when is_atom(M) ->
    case ncc_tracer_stack:compiler_frame({M, none, 0, []}) of
        true -> skip;
        false ->
            Md5 = case (try beam_lib:md5(Bin) catch _:_ -> error end) of
                      {ok, {M, Sum}} -> Sum;
                      _ -> bad
                  end,
            version(M, Md5, Ts),
            {M, Md5}
    end;
code_prepared(_M, _Bin, _Ts) -> skip.

version(M, Md5, Ts) ->
    Prepared = prepared(Md5, Ts, get({prepared, M})),
    put({prepared, M}, case is_list(Prepared) andalso length(Prepared) > ?MAX_PREPARED of
                           true -> overflow;
                           false -> Prepared
                       end),
    restored(M).

%% The prepared code a prepare returned, keyed by its reference until a
%% finish names it (or, when the finish was seen first, the finish's time).
%% A prepare that failed returns no reference.
prepared_ref(Entry, Ref) when is_reference(Ref), Entry =/= undefined ->
    case erase({finished_ref, Ref}) of
        undefined -> outstanding({prepared_ref, Ref}, Entry);
        Ts -> refs(-1), finished(Entry, Ts)
    end;
prepared_ref(_Entry, _Prepared) -> ok.

%% erlang:finish_loading/1 at Ts: each reference's code is loaded then. One
%% whose prepare was not seen yet waits for it; one never seen was prepared
%% before the trace or by the collector itself, which runs untraced.
code_finished(Refs, Ts) when is_list(Refs) ->
    lists:foreach(fun(Ref) when is_reference(Ref) ->
                          case erase({prepared_ref, Ref}) of
                              undefined -> outstanding({finished_ref, Ref}, Ts);
                              Entry -> refs(-1), finished(Entry, Ts)
                          end;
                     (_) -> ok
                  end, Refs);
code_finished(_Refs, _Ts) -> ok.

%% A finish called at Ts returned {on_load, Ms}: each M's code it finished
%% has an on_load function, which may run (erlang:call_on_load_function/1)
%% while the code current for M stays what it was. That is other code than
%% the toolchain's when any was prepared at or before Ts. Kept as the latest
%% such time.
finish_returned(Ts, {on_load, Ms}) when is_integer(Ts), is_list(Ms) ->
    lists:foreach(fun(M) -> on_load_ran(M, Ts) end, Ms);
finish_returned(_Ts, _Result) -> ok.

on_load_ran(M, Ts) when is_atom(M) ->
    put({on_load_ran, M}, case get({on_load_ran, M}) of
                              Old when is_integer(Old) -> max(Old, Ts);
                              _ -> Ts
                          end),
    restored(M);
on_load_ran(_M, _Ts) -> ok.

finished({M, Md5}, Ts) -> version(M, Md5, Ts);
finished(skip, _Ts) -> ok.

outstanding(Key, Value) ->
    put(Key, Value),
    refs(1) > ?MAX_REFS andalso swapped(overflow).

refs(N) ->
    Refs = case get(outstanding_refs) of
               undefined -> N;
               Old -> Old + N
           end,
    put(outstanding_refs, Refs),
    Refs.

prepared(_Md5, _Ts, overflow) -> overflow;
prepared(Md5, Ts, undefined) -> [{Md5, Ts, Ts}];
prepared(Md5, Ts, Prepared) ->
    case lists:keyfind(Md5, 1, Prepared) of
        {Md5, First, Last} -> lists:keyreplace(Md5, 1, Prepared, {Md5, min(First, Ts), max(Last, Ts)});
        false -> [{Md5, Ts, Ts} | Prepared]
    end.

toolchain_code(M, Md5) ->
    case get({toolchain_code, M}) of
        Known when is_list(Known) ->
            lists:member(Md5, Known) orelse put({toolchain_code, M}, [Md5 | Known]);
        _ -> put({toolchain_code, M}, [Md5])
    end,
    restored(M).

%% The toolchain's code prepared or finished at or after another version's
%% first prepare, or an on_load run at or after it.
restored(M) ->
    case {get({toolchain_code, M}), get({prepared, M})} of
        {Known, Prepared} when is_list(Known), is_list(Prepared) ->
            OnLoad = get({on_load_ran, M}),
            Swap = lists:any(fun({Md5, _First, Last}) ->
                                     lists:member(Md5, Known) andalso
                                         lists:any(fun({Other, First, _}) ->
                                                           Other =/= Md5 andalso First =< Last
                                                   end, Prepared)
                             end, Prepared)
                orelse (is_integer(OnLoad) andalso
                        lists:any(fun({Other, First, _}) ->
                                          not lists:member(Other, Known) andalso First =< OnLoad
                                  end, Prepared)),
            Swap andalso swapped(M);
        {Known, overflow} when is_list(Known) -> swapped(M);
        _ -> false
    end.

swapped(M) ->
    case get(code_swap) of
        undefined -> put(code_swap, M);
        _ -> ok
    end,
    true.

%% A kept verdict holds only for the code it was taken for.
cache_hit({Md5, V}, Md5) when is_binary(Md5), is_boolean(V) -> {ok, V};
cache_hit(_Entry, _Md5) -> miss.

verdict_env() ->
    #{roots => get(roots), preloaded_md5 => get(preloaded_md5), owned_md5 => get(owned_md5),
      realpath => fun abs_realpath/1, file_md5 => fun file_md5/1, old_code => fun old_code/1}.

%% A module with old code: a process may still run the code it had before
%% its last load, under the same name, whatever the current code is.
old_code(M) ->
    try erlang:check_old_code(M) catch _:_ -> true end.

%% Whether the code loaded for M, whose md5 is Md5 and whose recorded file
%% is Which (code:which/1), is the toolchain's. Neither the name nor the
%% recorded file decides: code:load_binary/3 records whatever file name it
%% is given, `preloaded` included. Toolchain only when
%%   * the module is one of the tracer's own, with the md5 it had at start;
%%   * the file is `preloaded` and so was the module at start, with this md5;
%%   * the file's real path lies under a root's real path, and the beam
%%     there is this module with this md5 (as code:modified_modules/0
%%     compares them).
%% Never while old code of the module exists (any frame of it may be
%% running that code). Nothing loaded, an unknown name, anything else: not
%% toolchain.
object_verdict(_M, _Which, undefined, _Env) -> false;
object_verdict(M, Which, Md5, #{old_code := Old} = Env) ->
    case (try Old(M) catch _:_ -> true end) of
        false -> current_verdict(M, Which, Md5, Env);
        _ -> false
    end;
object_verdict(_M, _Which, _Md5, _Env) -> false.

current_verdict(_M, _Which, undefined, _Env) -> false;
current_verdict(M, _Which, Md5, #{owned_md5 := Owned}) when is_map_key(M, Owned) ->
    maps:get(M, Owned) =:= Md5;
current_verdict(M, preloaded, Md5, #{preloaded_md5 := Pre}) ->
    maps:get(M, Pre, none) =:= Md5;
current_verdict(M, Which, Md5, #{roots := Roots, realpath := Real, file_md5 := FileMd5})
  when is_list(Which), Which =/= [] ->
    try Real(Which) of
        Path when is_list(Path) ->
            under_any(Path, Roots) andalso FileMd5(Path) =:= {ok, {M, Md5}};
        _ -> false
    catch
        _:_ -> false
    end;
current_verdict(_M, _Which, _Md5, _Env) -> false.

abs_realpath(Path) ->
    realpath(case filename:pathtype(Path) of
                 absolute -> Path;
                 _ -> filename:absname(Path)
             end).

%% The beam's module and md5, read the way the code server reads it
%% (erl_prim_loader also reads a beam inside an escript, rebar3's).
file_md5(Path) ->
    case erl_prim_loader:get_file(Path) of
        {ok, Bin, _} -> beam_lib:md5(Bin);
        _ -> error
    end.

under_any(Path, Roots) -> lists:any(fun(Root) -> lists:prefix(Root ++ "/", Path) end, Roots).

%% An absolute path is split as it is: filename:absname/1 asks the file
%% server for the working directory even then, and the collector must not
%% wait on a server the compile keeps busy (with a flooded mailbox, every
%% such call costs it a scan of what arrived meanwhile).
norm(Path) ->
    Abs = case filename:pathtype(Path) of
              absolute -> Path;
              _ -> filename:absname(Path)
          end,
    filename:join(lists:reverse(lists:foldl(fun norm_part/2, [], filename:split(Abs)))).

norm_part(".", Acc) -> Acc;
norm_part("..", ["/"] = Acc) -> Acc;
norm_part("..", [_ | Acc]) -> Acc;
norm_part(Part, Acc) -> [Part | Acc].

%% --- helpers ---------------------------------------------------------------

os_type_bin() ->
    {Family, Name} = os:type(),
    [atom_to_binary(Family), atom_to_binary(Name)].

start_line(Role, App, Depth) ->
    {ok, Cwd} = file:get_cwd(),
    #{kind => start, role => Role, app => bin(App), ts => now_ns(),
      cwd => ncc_tracer_channels:chars(Cwd), depth => Depth,
      otp_release => bin(erlang:system_info(otp_release)), elixir => elixir_version(),
      %% The byte order a compile-time endianness read returns here: the
      %% judge records it as a compile input a client compares.
      endian => atom_to_binary(erlang:system_info(endian)),
      %% The OS type a compile-time os:type/0 read returns here, as
      %% [Family, Name]: the judge records it as a compile input too.
      os_type => os_type_bin(),
      %% The scheduler count this VM runs with: a differential build's
      %% variant shows by it that its `+S` took (NccWorker.Portability.Differential).
      schedulers_online => erlang:system_info(schedulers_online),
      roots => [ncc_tracer_channels:chars(R) || R <- get(roots)],
      otp_root => ncc_tracer_channels:chars(code:root_dir()), elixir_root => elixir_root(),
      home => env_bin("HOME"), mix_home => ncc_tracer_channels:chars(mix_home()),
      hex_home => env_bin("HEX_HOME"), mode => env_bin("NCC_TRACE_MODE"),
      tracer => tracer_md5()}.

%% The md5 of every tracer module this VM runs. The report reader compares a
%% child VM's with the Mix VM's: a child that loaded other tracer beams (one
%% rewritten in <trace>/ebin after the Mix VM loaded its own) is not judged.
tracer_md5() ->
    maps:from_list([{atom_to_binary(M), binary:encode_hex(M:module_info(md5))}
                    || M <- [?MODULE, ncc_tracer_channels, ncc_tracer_stack]]).

elixir_version() ->
    case code:ensure_loaded('Elixir.System') of
        {module, _} -> 'Elixir.System':version();
        _ -> null
    end.

elixir_root() ->
    case code:lib_dir(elixir) of
        Dir when is_list(Dir) -> ncc_tracer_channels:chars(norm(filename:dirname(Dir)));
        _ -> null
    end.

call(Auth, Req) ->
    case collector() of
        undefined -> {error, no_tracer};
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {ncc_call, self(), Ref, Auth, Req},
            receive
                {Ref, Reply} ->
                    erlang:demonitor(Ref, [flush]),
                    Reply;
                {'DOWN', Ref, process, Pid, _} -> {error, no_tracer}
            after ?TIMEOUT ->
                erlang:demonitor(Ref, [flush]),
                {error, timeout}
            end
    end.

%% ok once every trace message generated so far is in the collector's queue;
%% a timeout is reported, and the window or end it guards fails.
delivered() ->
    Ref = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Ref} -> ok
    after env_int("NCC_TRACE_DELIVER_TIMEOUT_MS", ?TIMEOUT) -> {error, timeout}
    end.

random_hex() ->
    try binary:encode_hex(crypto:strong_rand_bytes(16))
    catch _:_ -> integer_to_binary(rand:uniform(1 bsl 128), 16)
    end.

%% The Mix VM's collector writes through a buffer (buffered/1): one write
%% per line is a dirty-IO NIF call each, which waits on the dirty IO
%% schedulers the compile keeps busy. The buffer is written out at every
%% request from the driver and before the file is closed. A collector that
%% dies with lines still buffered leaves no end line, and its watcher's
%% `collector_down` line, so the trace is not judged either way. A child
%% VM writes every line at once: rebar3 halts it without warning.
write(#st{fd = Fd}, Map) ->
    Line = try json:encode(Map) catch _:_ -> json:encode(#{kind => unencodable}) end,
    case get(write_buffer) of
        {Size, Acc} ->
            New = Size + iolist_size(Line) + 1,
            put(write_buffer, {New, [Acc, Line, $\n]}),
            case New >= ?WRITE_BUFFER of
                true -> write_out(Fd);
                false -> ok
            end;
        undefined -> ok = file:write(Fd, [Line, $\n])
    end.

buffered(main) ->
    _ = put(write_buffer, {0, []}),
    ok;
buffered(child) -> ok.

write_out(Fd) ->
    case get(write_buffer) of
        {0, _} -> ok;
        {_, Acc} ->
            _ = put(write_buffer, {0, []}),
            ok = file:write(Fd, Acc);
        undefined -> ok
    end.

now_ns() -> erlang:monotonic_time(nanosecond).

quietly(Fun) ->
    try Fun() catch _:_ -> error end.
pid_bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin(X) when is_binary(X) -> X;
bin(X) when is_atom(X) -> atom_to_binary(X);
bin(X) -> ncc_tracer_channels:chars(X).
to_list(X) when is_binary(X) -> binary_to_list(X);
to_list(X) when is_atom(X) -> atom_to_list(X);
to_list(X) when is_list(X) -> X.

env_bin(Name) ->
    case os:getenv(Name) of
        false -> null;
        V -> ncc_tracer_channels:chars(V)
    end.

env_int(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V -> try list_to_integer(V) catch _:_ -> Default end
    end.
