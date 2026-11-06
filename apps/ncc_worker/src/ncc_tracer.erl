-module(ncc_tracer).
%% Compile-time observation trace (precompiled portability spec, R1). Runs in
%% the VM that compiles the package: start_main/0 from `mix ncc.trace_compile`,
%% start_child/0 from ERL_AFLAGS in every other BEAM the compile starts
%% (rebar3). Writes one JSON object per line; NccWorker.Tracer.Report reads them.
-export([start_main/0, start_child/0, window_open/1, window_close/1, closure/2,
         native_patterns/2, finish/1, fire/1, ebin_dir/0, flush/0]).
%% Exported for the tests: stage-1 classification that never crashes.
-export([safe_extent/4]).

-define(DEPTH, 64).
-define(NAME, ncc_tracer_collector).
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
-record(st, {fd, session, initial = #{}, procs = #{}, native = #{}, sources = #{},
             spawning = #{}, set_depth = ?DEPTH, depth = ?DEPTH, lowered = false,
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
                ok = start(child, Dir, App),
                _ = fire(App),
                ok
        end
    catch
        _:_ -> ok
    end.

window_open(App) -> call({window_open, bin(App), now_ns()}).

window_close(App) ->
    delivered(),
    call({window_close, bin(App), now_ns()}).

closure(Packages, Deps) -> call({closure, [bin(P) || P <- Packages], Deps}).

native_patterns(App, Ebin) -> call({native, bin(App), to_list(Ebin)}).

finish(Status) ->
    _ = quietly(fun() -> fire("__final__") end),
    delivered(),
    call({finish, bin(Status), now_ns()}).

fire(App) -> ?PROBE:fire(to_list(App)).

%% Returns once every trace message generated before the call is written.
%% erlang:halt/0,1 stops the VM without running anything else, so a child
%% VM that halts right after its last compile loses the lines still queued
%% in the collector; a caller that can wait calls this before halting.
flush() ->
    delivered(),
    call(flush).

ebin_dir() -> filename:dirname(code:which(?MODULE)).

%% Stage 1 for one call. A stack the classifier cannot take apart (a frame
%% that is not a 4-tuple, a crash in IsToolchain) is user extent of its own
%% kind, `unjudged`: the event is written, never dropped.
safe_extent(Stack, Depth, IsToolchain, ProcessIsUser) ->
    try ncc_tracer_stack:extent(Stack, Depth, IsToolchain, ProcessIsUser) of
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
    Parent = self(),
    Opts = [monitor, {priority, high}, {message_queue_data, off_heap},
            {max_heap_size, #{size => env_int("NCC_TRACE_MAX_HEAP_WORDS", 33554432),
                              kill => true, error_logger => false}}],
    {Pid, Ref} = spawn_opt(fun() -> init(Parent, Role, Dir, App, Depth) end, Opts),
    receive
        {Pid, ready} ->
            erlang:demonitor(Ref, [flush]),
            set_child_env(Role);
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
    true = os:putenv("ERL_AFLAGS", Old ++ "-pa " ++ ebin_dir() ++ " -s ncc_tracer start_child"),
    ok;
set_child_env(child) -> ok.

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

init(Parent, Role, Dir, App, Depth) ->
    true = register(?NAME, self()),
    put(roots, roots()),
    {ok, Fd} = file:open(filename:join(Dir, file_name(Role, App)), [write, raw, binary]),
    %% Our own session (OTP 27+): a package's erlang:trace/3 or trace_pattern
    %% acts on the legacy session and cannot switch this one off.
    Session = trace:session_create(?NAME, self(), []),
    Flags = [call, procs, set_on_spawn, monotonic_timestamp],
    _ = trace:process(Session, existing, true, Flags),
    _ = trace:process(Session, self(), false, Flags),
    St = #st{fd = Fd, session = Session, set_depth = Depth, depth = Depth,
             initial = maps:from_keys(erlang:processes(), true),
             max_calls = env_int("NCC_TRACE_MAX_CALLS", 20000000),
             max_user = env_int("NCC_TRACE_MAX_USER_EVENTS", 200000),
             max_queue = env_int("NCC_TRACE_MAX_QUEUE", 2000000)},
    write(St, start_line(Role, App, Depth)),
    lists:foreach(fun(MFA) -> pattern(Session, MFA, Role, Depth) end,
                  ncc_tracer_channels:patterns() ++ spawn_patterns() ++ role_patterns(Role)),
    Parent ! {self(), ready},
    loop(St).

role_patterns(child) -> [{compile, file, 2}];
role_patterns(main) -> [].

%% Every spawn BIF: a spawn made in user extent makes the child a user
%% process, whatever it runs (Task.async(System, :get_env, [..]) from a
%% module body leaves only toolchain frames in the child).
spawn_patterns() ->
    [{erlang, F, A} || {F, A} <- erlang:module_info(exports), lists:member(F, ?SPAWNS)].

pattern(Session, {M, _, _} = MFA, Role, Depth) ->
    case code:ensure_loaded(M) of
        {module, M} -> _ = trace:function(Session, MFA, match_spec(MFA, Role, Depth), [global]), ok;
        _ -> ok
    end.

match_spec({compile, file, 2}, child, _Depth) -> [{'_', [], [{return_trace}]}];
match_spec(_MFA, _Role, Depth) -> [{'_', [], [{message, {current_stacktrace, Depth}}]}].

loop(St) ->
    receive
        {trace_ts, Pid, call, {M, F, Args}, Stack, Ts} ->
            loop(call_event(Pid, M, F, Args, Stack, Ts, St));
        {trace_ts, Pid, call, {compile, file, [Src | _]}, _Ts} ->
            loop(St#st{sources = maps:put(Pid, Src, St#st.sources)});
        {trace_ts, Pid, return_from, {compile, file, 2}, Result, Ts} ->
            loop(compiled(Pid, Result, Ts, St));
        {trace_ts, Parent, spawn, Child, MFA, _Ts} ->
            loop(spawned(Child, Parent, MFA, St));
        {trace_ts, Pid, exit, _Reason, _Ts} ->
            loop(St#st{procs = maps:remove(Pid, St#st.procs),
                       spawning = maps:remove(Pid, St#st.spawning)});
        {ncc_call, From, Ref, Req} ->
            {Reply, St1} = request(Req, St),
            From ! {Ref, Reply},
            continue(Req, St1);
        _Other ->
            loop(St)
    end.

continue({finish, _, _}, _St) -> ok;
continue(_Req, St) -> loop(St).

call_event(_Pid, _M, _F, _Args, _Stack, _Ts, #st{overflow = true} = St) -> St;
call_event(Pid, M, F, Args, Stack, Ts, #st{calls = Calls} = St0) ->
    case check_limits(St0#st{calls = Calls + 1}) of
        #st{overflow = true} = St -> St;
        St1 ->
            St = depth_seen(M, F, Args, St1),
            Extent = safe_extent(Stack, St#st.depth, fun toolchain/1, user_process(Pid, St)),
            classified(M, F, Args, Extent, {Pid, M, F, Args, Ts}, St)
    end.

classified(erlang, F, _Args, Extent, {Pid, _, _, _, _}, St) when F =:= spawn; F =:= spawn_link;
                                                                 F =:= spawn_monitor; F =:= spawn_opt;
                                                                 F =:= spawn_request ->
    spawn_call(Pid, Extent, St);
classified(M, F, Args, Extent, Info, St) ->
    record(channel(M, F, Args, St), Extent, Info, St).

%% A package can lower backtrace_depth (phoenix's start/2 sets it). Stacks
%% are cut at the live value, so they are judged against it, and the next
%% check reports the window even when the flag was put back meanwhile.
depth_seen(erlang, system_flag, [backtrace_depth, N], #st{set_depth = Set} = St)
  when is_integer(N), N >= 0 ->
    Live = min(N, Set),
    St#st{depth = Live, lowered = St#st.lowered orelse Live < Set};
depth_seen(_M, _F, _Args, St) -> St.

%% Set it back (system_info has no backtrace_depth key, so reading it means
%% setting it) and report whether it held since the last window close. A
%% sentinel checks too but keeps what it found for the close, which is the
%% check the judge reads for the window.
depth_check(St) -> depth_check(St, close).

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
record(unknown, _Extent, _Info, St) -> St;
record({env, #{name := <<?SENTINEL, App/binary>>}}, {user, _, _, {?PROBE, _, _, _}},
       {Pid, _, _, _, Ts}, St0) ->
    {DepthOk, St} = depth_check(St0, sentinel),
    write(St, #{kind => sentinel, app => App, ts => Ts, pid => pid_bin(Pid), depth_ok => DepthOk}),
    St#st{final = St#st.final orelse App =:= <<"__final__">>};
record({Channel, Arg}, {user, Kind0, First0, User0}, {Pid, M, F, Args, Ts}, St) ->
    {Kind, First, User} = frames(Kind0, First0, User0),
    Line = #{kind => event, ts => Ts, pid => pid_bin(Pid), channel => Channel,
             mfa => ncc_tracer_stack:mfa_bin(M, F, length(Args)),
             arg => enrich(Channel, Arg), extent => Kind, first => First, user => User},
    user_event(Line, Kind =:= unjudged orelse Channel =:= unclassified, St).

%% A frame the renderer cannot take apart turns the event unjudged, with no
%% frames, rather than crashing the collector or dropping the event.
frames(Kind, First, User) ->
    try {Kind, ncc_tracer_stack:frame(First), ncc_tracer_stack:frame(User)}
    catch _:_ -> {unjudged, null, null}
    end.

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
spawned(Child, Parent, MFA, St) ->
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
    St#st{sources = maps:remove(Pid, St#st.sources)}.

compile_result(Result) when is_tuple(Result), element(1, Result) =:= ok -> ok;
compile_result(_Result) -> error.

compile_module(Result) when is_tuple(Result), element(1, Result) =:= ok,
                            tuple_size(Result) >= 2, is_atom(element(2, Result)) ->
    atom_to_binary(element(2, Result));
compile_module(_Result) -> null.

%% --- requests ----------------------------------------------------------------

request({window_open, App, Ts}, St) ->
    write(St, #{kind => window_open, app => App, ts => Ts}),
    {ok, St};
request({window_close, App, Ts}, St0) ->
    {DepthOk, St} = depth_check(St0),
    write(St, #{kind => window_close, app => App, ts => Ts, depth_ok => DepthOk}),
    {ok, St};
request({closure, Packages, Deps}, St) ->
    write(St, #{kind => closure, packages => Packages, deps => Deps, ts => now_ns()}),
    {ok, St};
request({native, App, Ebin}, St) -> {ok, native(App, Ebin, St)};
request({finish, Status, Ts}, St) -> {finish_trace(Status, Ts, St), St};
request(flush, St) -> {ok, St};
request(_Req, St) -> {{error, unknown_request}, St}.

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
    lists:foreach(fun(M) ->
                          trace:function(Session, {M, '_', '_'}, match_spec(M, main, Depth),
                                         [global])
                  end, Mods),
    delivered(),
    write(St, #{kind => quiet_close, app => App, ts => now_ns()}),
    St#st{native = maps:merge(St#st.native, maps:from_keys(Mods, App))}.

beam_modules(Ebin) ->
    [list_to_atom(filename:basename(F, ".beam")) || F <- filelib:wildcard("*.beam", Ebin)].

finish_trace(Status, Ts, #st{fd = Fd, session = Session} = St0) ->
    {DepthOk, St} = depth_check(St0),
    write(St, #{kind => stats, calls => St#st.calls, user_events => St#st.user,
                truncated => St#st.truncated, unjudged => St#st.unjudged,
                spawned => St#st.spawned}),
    write(St, #{kind => 'end', ts => Ts, status => Status, depth_ok => DepthOk,
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
      hex_home => env_bin("HEX_HOME")}.

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

call(Req) ->
    case whereis(?NAME) of
        undefined -> {error, no_tracer};
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {ncc_call, self(), Ref, Req},
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

delivered() ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok after ?TIMEOUT -> ok end.

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
