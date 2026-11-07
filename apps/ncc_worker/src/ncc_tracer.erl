-module(ncc_tracer).
%% Compile-time observation trace (precompiled portability spec, R1). Runs in
%% the VM that compiles the package: start_main/0 from `mix ncc.trace_compile`,
%% start_child/0 from ERL_AFLAGS in every other BEAM the compile starts
%% (rebar3). Writes one JSON object per line; NccWorker.Tracer.Report reads them.
-export([start_main/0, start_child/0, window_open/2, window_close/2, closure/3,
         native_patterns/3, finish/2, fire/1, ebin_dir/0, flush/0, collector/0]).
%% Exported for the tests: stage-1 classification that never crashes.
-export([safe_extent/4, maps_libs/1]).

-define(DEPTH, 64).
-define(COLLECTOR, {?MODULE, collector}).
-define(PROBE, ncc_tracer_probe).
-define(SENTINEL, "NCC_TRACE_SENTINEL:").
-define(TIMEOUT, 120000).
-define(INTROSPECTION, ['__info__', module_info, behaviour_info]).
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
%% token: the secret start/3 hands the driver; every request but flush must
%% carry it. watcher, wref: the process that records the collector's death,
%% monitored in turn. tampered: a forged request or a dead watcher was seen;
%% it fails every check until the end.
-record(st, {fd, file, session, initial = #{}, procs = #{}, native = #{}, sources = #{},
             spawning = #{}, parents = #{}, set_depth = ?DEPTH, depth = ?DEPTH, lowered = false,
             wanted = [], unpatterned = false, final_pid, final_nonce,
             token, watcher, wref, tampered = false, libs = unavailable, libs_written = false,
             calls = 0, user = 0, truncated = 0, unjudged = 0, spawned = 0,
             max_calls, max_user, max_queue, overflow = false, final = false}).

%% --- API used by the driver ---------------------------------------------

start_main() ->
    Dir = os:getenv("NCC_TRACE_DIR"),
    case os:getenv("MIX_OS_DEPS_COMPILE_PARTITION_COUNT") of
        V when V =:= false; V =:= "" -> start(main, Dir, "main");
        _ -> refuse_start(Dir, <<"partitions">>)
    end.

start_child() ->
    try
        case os:getenv("NCC_TRACE_DIR") of
            false -> ok;
            Dir ->
                App = child_app(),
                {ok, _Token} = start(child, Dir, App),
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

native_patterns(Token, App, Ebin) -> call(Token, {native, bin(App), to_list(Ebin)}).

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

start(_Role, false, _App) -> {error, no_trace_dir};
start(Role, Dir, App) ->
    %% The set returns the old value; the second set reads back what the
    %% first one left, which is the depth every stack is judged against.
    _ = erlang:system_flag(backtrace_depth, ?DEPTH),
    Depth = erlang:system_flag(backtrace_depth, ?DEPTH),
    ok = load_probe(),
    Script = mix_script(Role),
    Libs = start_libs(),
    Parent = self(),
    Opts = [monitor, {priority, high}, {message_queue_data, off_heap},
            {max_heap_size, #{size => env_int("NCC_TRACE_MAX_HEAP_WORDS", 33554432),
                              kill => true, error_logger => false}}],
    {Pid, Ref} = spawn_opt(fun() -> init(Parent, Role, Dir, App, Depth, Script, Libs) end, Opts),
    receive
        {Pid, ready, Token} ->
            erlang:demonitor(Ref, [flush]),
            persistent_term:put(?COLLECTOR, Pid),
            ok = set_child_env(Role),
            {ok, Token};
        {'DOWN', Ref, process, Pid, Reason} -> {error, Reason}
    after ?TIMEOUT -> {error, timeout}
    end.

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

init(Parent, Role, Dir, App, Depth, Script, Libs) ->
    put(mix_script, Script),
    put(driver, Parent),
    put(roots, roots()),
    File = filename:join(Dir, file_name(Role, App)),
    {ok, Fd} = file:open(File, [write, raw, binary]),
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
    St0 = #st{fd = Fd, file = File, session = Session, set_depth = Depth, depth = Depth,
              token = Token,             initial = maps:from_keys(erlang:processes(), true),
             max_calls = env_int("NCC_TRACE_MAX_CALLS", 20000000),
             max_user = env_int("NCC_TRACE_MAX_USER_EVENTS", 200000),
             max_queue = env_int("NCC_TRACE_MAX_QUEUE", 2000000)},
    write(St0, maps:merge((start_line(Role, App, Depth))#{mix_script => script_bin(Script)},
                          libs_fields(Libs))),
    Wanted = [wanted(Session, MFA, match_spec(MFA, Role, Depth))
              || MFA <- ncc_tracer_channels:patterns() ++ spawn_patterns() ++ role_patterns(Role)],
    St = watcher(St0#st{wanted = Wanted, libs = Libs}),
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

role_patterns(child) -> [{compile, file, 2}];
role_patterns(main) -> [].

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
patterns_check(#st{unpatterned = Lost, overflow = Overflow} = St0, When) ->
    {Patterned, St} = case Overflow of
                          true -> {false, St0};
                          false -> repatterned(St0)
                      end,
    Ok = Patterned andalso not Lost,
    {Ok, St#st{unpatterned = When =:= sentinel andalso not Ok}}.

repatterned(#st{session = Session, wanted = Wanted} = St) ->
    try
        Checked = [rewanted(Session, W) || W <- Wanted],
        {lists:all(fun({Ok, _}) -> Ok end, Checked), St#st{wanted = [W || {_, W} <- Checked]}}
    catch
        _:_ -> {false, St}
    end.

rewanted(Session, {MFA, MS, Loaded} = W) ->
    case traced(Session, MFA, Loaded) of
        true -> {true, W};
        false -> {false, wanted(Session, MFA, MS)}
    end.

traced(Session, {M, F, A}, WasLoaded) ->
    case erlang:module_loaded(M) of
        false -> not WasLoaded;
        true ->
            lists:all(fun(MFA) -> trace:info(Session, MFA, traced) =:= {traced, global} end,
                      concrete(M, F, A))
    end.

concrete(M, '_', '_') -> [{M, F, A} || {F, A} <- M:module_info(exports)];
concrete(M, F, A) ->
    case erlang:function_exported(M, F, A) of
        true -> [{M, F, A}];
        false -> []
    end.

match_spec({compile, file, 2}, child, _Depth) -> [{'_', [], [{return_trace}]}];
match_spec({erlang, process_info, 2}, _Role, Depth) ->
    Msg = {message, {current_stacktrace, Depth}},
    [{['_', Item], [], [Msg]} || Item <- [dictionary, backtrace, messages, {dictionary, '_'}]]
        ++ [{['_', '$1'], [{is_list, '$1'}], [Msg]}];
match_spec(_MFA, _Role, Depth) -> [{'_', [], [{message, {current_stacktrace, Depth}}]}].

loop(St) ->
    receive
        {trace_ts, _Pid, _What, _, _} = Msg -> loop(traced(Msg, St));
        {trace_ts, _Pid, _What, _, _, _} = Msg -> loop(traced(Msg, St));
        {ncc_call, From, Ref, Auth, Req} when Auth =:= St#st.token; Req =:= flush ->
            {Reply, St1} = request(Req, From, St),
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

traced({trace_ts, Pid, call, {M, F, Args}, Stack, Ts}, St) ->
    call_event(Pid, M, F, Args, Stack, Ts, St);
traced({trace_ts, Pid, call, {compile, file, [Src | _]}, _Ts}, St) ->
    St#st{sources = maps:put(Pid, Src, St#st.sources)};
traced({trace_ts, Pid, call, {M, F, Args}, Ts}, St) ->
    %% A call with no stack: our match spec was replaced. Unjudged.
    call_event(Pid, M, F, Args, no_stack, Ts, St);
traced({trace_ts, Pid, return_from, {compile, file, 2}, Result, Ts}, St) ->
    compiled(Pid, Result, Ts, St);
traced({trace_ts, Parent, spawn, Child, MFA, _Ts}, St) ->
    spawned(Child, Parent, MFA, St);
traced({trace_ts, Child, spawned, Parent, _MFA, _Ts}, St) ->
    case is_map_key(Child, St#st.procs) of
        true -> St;
        false -> St#st{parents = maps:put(Child, Parent, St#st.parents)}
    end;
traced({trace_ts, Pid, exit, _Reason, _Ts}, St) ->
    St#st{procs = maps:remove(Pid, St#st.procs), spawning = maps:remove(Pid, St#st.spawning),
          parents = maps:remove(Pid, St#st.parents)};
traced(_Msg, St) -> St.

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
                {trace_ts, Parent, _, _, _} = Msg -> await_parent(Child, Parent, traced(Msg, St), Deadline);
                {trace_ts, Parent, _, _, _, _} = Msg -> await_parent(Child, Parent, traced(Msg, St), Deadline)
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
             extent => unjudged, first => null, user => null},
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
            Info = {Pid, M, F, Args, Ts, {caller(Stack), bottom(Stack, St#st.depth)}},
            classified(M, F, Args, Extent, Info, St)
    end.

classified(erlang, F, _Args, Extent, {Pid, _, _, _, _, _}, St) when F =:= spawn; F =:= spawn_link;
                                                                 F =:= spawn_monitor; F =:= spawn_opt;
                                                                 F =:= spawn_request ->
    spawn_call(Pid, Extent, St);
classified(M, F, Args, Extent, Info, St) ->
    record(channel(M, F, Args, St), Extent, Info, St).

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
    {Ok, St#st{depth = Set, lowered = When =:= sentinel andalso not Ok}}.

channel(M, F, Args, St) ->
    try ncc_tracer_channels:classify(M, F, Args) of
        unknown -> native_channel(M, F, St);
        {Channel, Summary} when is_atom(Channel), is_map(Summary) -> {Channel, Summary};
        _Other -> {unclassified, #{}}
    catch
        _:_ -> {unclassified, #{}}
    end.

%% Any call into a natively built closure dependency's modules (spec R3),
%% except the introspection the Elixir compiler itself makes while it expands
%% a call to such a module (`__info__(:macros)` and friends): that returns
%% compile metadata, not a value the native build produced.
native_channel(M, F, St) ->
    case is_map_key(M, St#st.native) andalso not lists:member(F, ?INTROSPECTION) of
        true -> {native_closure, #{module => atom_to_binary(M)}};
        false -> unknown
    end.

record(_Class, toolchain, _Info, St) -> St;
record(unknown, {user, unjudged, _, _}, _Info, St) -> St#st{unjudged = St#st.unjudged + 1};
record(unknown, _Extent, _Info, St) -> St;
record({env, #{name := <<?SENTINEL, App0/binary>>}}, {user, _, _, {?PROBE, _, _, _}},
       {Pid, _, _, _, Ts, _}, St0) ->
    {Checks, St} = checks(St0, sentinel),
    {App, Final} = sentinel_app(App0, Pid, St),
    write(St, Checks#{kind => sentinel, app => App, ts => Ts, pid => pid_bin(Pid)}),
    St#st{final = St#st.final orelse Final};
record({Channel, Arg}, {user, Kind0, First0, User0}, {Pid, M, F, Args, Ts, Ends}, St) ->
    {Kind, First, User, {Caller, Bottom}} = frames(Kind0, First0, User0, Ends),
    Line = #{kind => event, ts => Ts, pid => pid_bin(Pid), channel => Channel,
             mfa => ncc_tracer_stack:mfa_bin(M, F, length(Args)),
             arg => enrich(Channel, Arg), extent => Kind, first => First, user => User,
             caller => Caller, bottom => Bottom},
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
    {#{depth_ok => DepthOk, integrity_ok => PatternsOk andalso not St#st.tampered}, St}.

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

toolchain_app(App) ->
    case code:lib_dir(App) of
        Dir when is_list(Dir) -> under_any(norm(Dir), get(install_roots));
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
    Source = ncc_tracer_channels:chars(maps:get(Pid, St#st.sources, null)),
    write(St, #{kind => compile, ts => Ts, source => Source,
                result => compile_result(Result), module => compile_module(Result)}),
    libs_line(St#st{sources = maps:remove(Pid, St#st.sources)}).

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
    {ok, St};
request({window_close, App, Ts, Delivered}, _From, St0) ->
    {Checks, St} = closing_checks(St0, Delivered),
    write(St, (maps:merge(Checks, libs_fields(mapped_libs())))#{kind => window_close, app => App,
                                                                ts => Ts}),
    {ok, St};
request({closure, Packages, Deps}, _From, St) ->
    write(St, #{kind => closure, packages => Packages, deps => Deps, ts => now_ns()}),
    {ok, St};
request({native, App, Ebin}, _From, St) -> {ok, native(App, Ebin, St)};
request(final_nonce, From, St) ->
    Nonce = random_hex(),
    {Nonce, St#st{final_pid = From, final_nonce = Nonce}};
request({finish, Status, Ts, Delivered}, _From, St) ->
    {finish_trace(Status, Ts, Delivered, St), St};
request(flush, _From, St) -> {ok, libs_line(St)};
request(_Req, _From, St) -> {{error, unknown_request}, St}.

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
                spawned => St#st.spawned}),
    write(St, (maps:merge(Checks, libs_fields(mapped_libs())))#{kind => 'end', ts => Ts,
                                                                status => Status,
                      final_sentinel => St#st.final, overflow => St#st.overflow}),
    _ = file:close(Fd),
    _ = quietly(fun() -> trace:session_destroy(Session) end),
    ok.

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

roots() ->
    Otp = [norm(code:root_dir())],
    Elixir = case code:lib_dir(elixir) of
                 Dir when is_list(Dir) -> [norm(filename:dirname(Dir))];
                 _ -> []
             end,
    put(install_roots, Otp ++ Elixir),
    Homes = [norm(mix_home()) | [norm(H) || H <- [os:getenv("HEX_HOME")], H =/= false, H =/= ""]],
    Otp ++ Elixir ++ Homes ++ [norm(ebin_dir())].

mix_home() ->
    case os:getenv("MIX_HOME") of
        V when V =:= false; V =:= "" -> filename:join(os:getenv("HOME", "/"), ".mix");
        V -> V
    end.

toolchain(M) ->
    case get({tc, M}) of
        undefined ->
            V = toolchain_module(M),
            put({tc, M}, V),
            V;
        V -> V
    end.

%% A module with no object file (elixir_compiler_N running a module body,
%% a module defined from a string, the sentinel probe) is not toolchain.
toolchain_module(M) ->
    case code:which(M) of
        preloaded -> true;
        Path when is_list(Path), Path =/= [] -> under_any(norm(Path), get(roots));
        _ -> false
    end.

under_any(Path, Roots) -> lists:any(fun(Root) -> lists:prefix(Root ++ "/", Path) end, Roots).

norm(Path) ->
    Parts = filename:split(filename:absname(Path)),
    filename:join(lists:reverse(lists:foldl(fun norm_part/2, [], Parts))).

norm_part(".", Acc) -> Acc;
norm_part("..", ["/"] = Acc) -> Acc;
norm_part("..", [_ | Acc]) -> Acc;
norm_part(Part, Acc) -> [Part | Acc].

%% --- helpers ---------------------------------------------------------------

start_line(Role, App, Depth) ->
    {ok, Cwd} = file:get_cwd(),
    #{kind => start, role => Role, app => bin(App), ts => now_ns(),
      cwd => ncc_tracer_channels:chars(Cwd), depth => Depth,
      otp_release => bin(erlang:system_info(otp_release)), elixir => elixir_version(),
      roots => [ncc_tracer_channels:chars(R) || R <- get(roots)],
      otp_root => ncc_tracer_channels:chars(code:root_dir()), elixir_root => elixir_root(),
      home => env_bin("HOME"), mix_home => ncc_tracer_channels:chars(mix_home()),
      hex_home => env_bin("HEX_HOME"), tracer => tracer_md5()}.

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

write(#st{fd = Fd}, Map) ->
    Line = try json:encode(Map) catch _:_ -> json:encode(#{kind => unencodable}) end,
    ok = file:write(Fd, [Line, $\n]).

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
