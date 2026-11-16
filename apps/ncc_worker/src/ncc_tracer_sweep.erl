-module(ncc_tracer_sweep).
%% The driver's sweep at each window boundary (NccWorker.Tracer). A natively
%% built dependency runs programs the trace does not follow (make, cmake,
%% cargo, a rebar3 port compiler), and one of them can leave a process
%% behind: alive while a later dependency's window is open, it could rewrite
%% that dependency's source for its compile to read and put the bytes back
%% before the window closes, which neither the tree check nor the window-close
%% digest would see. So before each window closes the collector, which is not
%% traced, kills every process in the container that started after the traced
%% VM, except that VM's own erl_child_setup, and checks that none is left.
%%
%% Everything that started no later than the traced VM is its launch chain:
%% the worker (pid 1) and its helper, timeout(1), fakeroot and its faked. The
%% worker swept the container just before it started the compile
%% (NccWorker.ProcessSweep), and nothing runs package code before the VM
%% does, so nothing older is anyone else's. Zombies are left alone unless a
%% thread of theirs still runs (a process whose first thread exited on its
%% own); killing such a pid kills its threads. Kills go one pid at a time,
%% never to a group or -1, and the scan repeats until nothing is left or the
%% rounds run out.
%%
%% Only in the worker's container: the worker passes its own start time
%% (NCC_TRACE_SWEEP), and the sweep runs only on Linux with a /proc whose pid
%% 1 started then. Anywhere else (a developer's machine, CI) it is
%% `unavailable` and kills nothing; a trace asked to sweep fails then.
-export([sweep/1, sweep/2, parse_stat/1, kill/1, kill/2]).

-include_lib("kernel/include/file.hrl").

-define(ROUNDS, 20).
-define(INTERVAL_MS, 100).
-define(KILL_TIMEOUT_MS, 2000).
-define(HELPER, <<"erl_child_setup">>).
-define(DEAD, [<<"Z">>, <<"X">>, <<"x">>]).
%% Where kill(1) and a POSIX shell are looked for: fixed paths, never the
%% traced VM's PATH (kill/2).
-define(KILLS, ["/bin/kill", "/usr/bin/kill"]).
-define(SHELLS, ["/bin/sh", "/usr/bin/sh"]).
%% What a sweep line lists of the processes it killed or that survived.
-define(MAX_LISTED, 20).

-type proc() :: #{pid := pos_integer(), ppid := non_neg_integer(), comm := binary(),
                  state := binary(), start_time := non_neg_integer()}.
-type result() :: {ok, [proc()]} | {survivors, [proc()], [proc()]} | {unavailable, binary()}.

-spec sweep(string()) -> result().
sweep(Expected) -> sweep(Expected, #{}).

%% Expected: pid 1's start time, in clock ticks, as the worker read it.
%% Opts (tests): proc_root, self_pid, os_type, kill (a fun given pids),
%% rounds, interval_ms.
-spec sweep(string(), map()) -> result().
sweep(Expected, Opts) ->
    Root = maps:get(proc_root, Opts, "/proc"),
    Self = maps:get(self_pid, Opts, list_to_integer(os:getpid())),
    case available(Expected, Root, Self, maps:get(os_type, Opts, os:type())) of
        ok ->
            rounds(Root, Self, maps:get(kill, Opts, fun kill/1),
                   maps:get(rounds, Opts, ?ROUNDS), maps:get(interval_ms, Opts, ?INTERVAL_MS),
                   []);
        {unavailable, _} = Unavailable -> Unavailable
    end.

%% Everything that started no later than the traced VM is kept, so the start
%% times must order the VM after the worker, or nothing would ever be killed.
available(Expected, Root, Self, {unix, linux}) ->
    case {integer(Expected), read_stat(Root, "1"), read_stat(Root, integer_to_list(Self))} of
        {error, _, _} -> {unavailable, <<"no start time of the worker to check">>};
        {_, error, _} -> {unavailable, <<"no /proc/1/stat">>};
        {_, _, error} -> {unavailable, <<"the traced VM is not in /proc">>};
        {Start, {ok, #{start_time := Start}}, {ok, #{start_time := Vm}}} when Vm > Start -> ok;
        {Start, {ok, #{start_time := Start}}, {ok, _}} ->
            {unavailable, <<"start times do not order the traced VM after the worker">>};
        {_, {ok, _}, _} -> {unavailable, <<"pid 1 is not the worker that asked">>}
    end;
available(_Expected, _Root, _Self, OsType) ->
    {unavailable, iolist_to_binary(io_lib:format("not Linux (~0p)", [OsType]))}.

integer(Text) ->
    try list_to_integer(Text)
    catch _:_ -> error
    end.

rounds(Root, Self, Kill, Left, Interval, Killed) ->
    case strays(Root, Self) of
        error -> {unavailable, <<"the traced VM is not in /proc">>};
        [] -> {ok, Killed};
        Procs when Left =:= 0 -> {survivors, Procs, Killed};
        Procs ->
            _ = Kill([Pid || #{pid := Pid} <- Procs]),
            _ = Interval > 0 andalso timer:sleep(Interval),
            rounds(Root, Self, Kill, Left - 1, Interval,
                   lists:sublist(Killed ++ Procs, ?MAX_LISTED))
    end.

%% The live processes that started after Self, but for Self's own helper.
strays(Root, Self) ->
    Procs = scan(Root),
    case [P || #{pid := Pid} = P <- Procs, Pid =:= Self] of
        [#{start_time := Start}] ->
            Helper = helper(Procs, Self),
            [P || #{pid := Pid, start_time := T} = P <- Procs,
                  Pid =/= Self, Pid =/= Helper, T > Start, live(Root, P)];
        _ -> error
    end.

helper(Procs, Self) ->
    case lists:sort([{T, Pid} || #{ppid := Parent, comm := ?HELPER, start_time := T, pid := Pid}
                                     <- Procs, Parent =:= Self]) of
        [{_, Pid} | _] -> Pid;
        [] -> none
    end.

live(Root, #{state := State, pid := Pid}) ->
    case lists:member(State, ?DEAD) of
        false -> true;
        true -> live_thread(filename:join([Root, integer_to_list(Pid), "task"]))
    end.

%% A zombie's threads, each under task/<tid>/stat. One whose threads cannot
%% be listed has gone, threads and all.
live_thread(TaskRoot) ->
    lists:any(fun(#{state := State}) -> not lists:member(State, ?DEAD) end, scan(TaskRoot)).

scan(Root) ->
    case file:list_dir(Root) of
        {ok, Names} ->
            [P || Name <- Names, digits(Name), {ok, P} <- [read_stat(Root, Name)]];
        {error, _} -> []
    end.

digits(Name) -> Name =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Name).

read_stat(Root, Name) ->
    case file:read_file(filename:join([Root, Name, "stat"])) of
        {ok, Bin} -> parse_stat(Bin);
        {error, _} -> error
    end.

%% One /proc/<pid>/stat line. comm sits in parentheses and may hold blanks
%% and parentheses itself, so the fields after it are read from the last ")".
-spec parse_stat(binary()) -> {ok, proc()} | error.
parse_stat(Bin) when is_binary(Bin) ->
    try
        [PidText, Rest] = binary:split(Bin, <<" (">>),
        {At, 1} = lists:last(binary:matches(Rest, <<")">>)),
        Comm = binary:part(Rest, 0, At),
        After = binary:part(Rest, At + 1, byte_size(Rest) - At - 1),
        %% Fields 3 (state), 4 (ppid) ... 22 (starttime), counted from 1.
        [State, Ppid | More] = binary:split(string:trim(After), <<" ">>, [global]),
        {ok, #{pid => binary_to_integer(PidText), ppid => binary_to_integer(Ppid),
               comm => Comm, state => State,
               start_time => binary_to_integer(lists:nth(18, More))}}
    catch
        _:_ -> error
    end;
parse_stat(_Other) -> error.

%% SIGKILL by pid, through kill(1) or, without one, the POSIX shell's
%% builtin (dash's rejects `--`). Whether they died is for the next scan.
%%
%% The program runs after a window's compile and before the digest that
%% closes it, so nothing package code can set may choose what runs then. It
%% can set the traced VM's environment (os:putenv/2 is observed, never
%% refused): the program is found at a fixed path, never by PATH, and runs
%% with every name in that environment unset, so no LD_PRELOAD, LD_AUDIT or
%% exported shell function of the package's is loaded into it.
-spec kill([pos_integer()]) -> ok | {error, no_kill | timeout}.
kill(Pids) -> kill(Pids, {?KILLS, ?SHELLS}).

%% Programs (tests): {kill(1)s, shells}, the first executable of each.
-spec kill([pos_integer()], {[file:filename()], [file:filename()]}) ->
          ok | {error, no_kill | timeout}.
kill(Pids, {Kills, Shells}) ->
    Args = [integer_to_list(Pid) || Pid <- Pids],
    case {executable(Kills), executable(Shells)} of
        {false, false} -> {error, no_kill};
        {false, Sh} -> run(Sh, ["-c", "kill -KILL \"$@\"", "sh" | Args]);
        {Kill, _} -> run(Kill, ["-KILL", "--" | Args])
    end.

executable(Paths) ->
    case [Path || Path <- Paths, executable_file(Path)] of
        [Path | _] -> Path;
        [] -> false
    end.

executable_file(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, mode = Mode}} -> Mode band 8#111 =/= 0;
        _ -> false
    end.

%% open_port/2 starts from the VM's environment and can only change names in
%% it: each one is unset.
cleared_env() ->
    [{Name, false} || Var <- os:getenv(), Name <- [env_name(Var)], Name =/= []].

env_name(Var) -> lists:takewhile(fun(C) -> C =/= $= end, Var).

run(Program, Args) ->
    try open_port({spawn_executable, Program},
                  [{args, Args}, {env, cleared_env()}, exit_status, stderr_to_stdout,
                   binary, hide]) of
        Port -> wait(Port, erlang:monotonic_time(millisecond) + ?KILL_TIMEOUT_MS)
    catch
        _:_ -> {error, no_kill}
    end.

wait(Port, Deadline) ->
    Left = max(Deadline - erlang:monotonic_time(millisecond), 0),
    receive
        {Port, {data, _}} -> wait(Port, Deadline);
        {Port, {exit_status, _}} -> ok
    after Left ->
        catch port_close(Port),
        {error, timeout}
    end.
