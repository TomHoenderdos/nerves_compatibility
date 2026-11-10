-module(code_loading_repro).
%% The research's reproduction (research/2026-11-10-tracer-host-reads.md,
%% C1): in an archive escript, as rebar3 is one, the first call into an
%% unloaded OTP module makes the calling process read the beam itself
%% (code:ensure_loaded/1 -> erl_prim_loader:read_file/1), and erl_prim_loader
%% resolves the path against the primary archive: system_info(os_type),
%% prim_file:read_link/1 on every path prefix, prim_file:get_cwd/0. Prints
%% the distinct stacks of those reads, top down to code:ensure_loaded/1, as
%% the term the pinned table holds: {shapes, OtpRelease, Shapes}.
-export([main/1, build/1]).

build(Out) ->
    {ok, ?MODULE, Beam} = compile:file("code_loading_repro.erl", [binary, debug_info]),
    ok = escript:create(Out, [shebang, {emu_args, "-escript main code_loading_repro"},
                              {archive, [{"code_loading_repro.beam", Beam}], []}]),
    halt(0).

main(_) ->
    Self = self(),
    Col = spawn(fun() -> loop(Self, []) end),
    _ = erlang:system_flag(backtrace_depth, 64),
    MS = [{'_', [], [{message, {current_stacktrace, 64}}]}],
    [erlang:trace_pattern(MFA, MS, [global])
     || MFA <- [{erlang, system_info, 1}, {prim_file, read_link, 1}, {prim_file, get_cwd, 0}]],
    erlang:trace(self(), true, [call, {tracer, Col}]),
    false = erlang:module_loaded(erl_syntax),
    _ = erl_syntax:string("undefined"),
    false = erlang:module_loaded(public_key),
    _ = public_key:pem_decode(<<>>),
    erlang:trace(self(), false, [call]),
    Col ! {done, self()},
    Events = receive {events, Es} -> Es after 10000 -> [] end,
    Shapes = lists:usort([shape(MFA, Stack) || {MFA, Args, Stack} <- Events, wanted(MFA, Args)]),
    io:format("~p.~n", [{shapes, erlang:system_info(otp_release), [S || {ok, S} <- Shapes]}]),
    io:format("~p.~n", [{unmatched, [U || {unmatched, U} <- Shapes]}]).

wanted({erlang, system_info, 1}, [os_type]) -> true;
wanted({erlang, system_info, 1}, _) -> false;
wanted(_, _) -> true.

shape(MFA, Stack) ->
    Frames = [{M, F, arity(A)} || {M, F, A, _} <- Stack],
    case lists:splitwith(fun(Fr) -> Fr =/= {code, ensure_loaded, 1} end, Frames) of
        {Top, [Ensure | _]} -> {ok, Top ++ [Ensure]};
        {_, []} -> {unmatched, {MFA, Frames}}
    end.

arity(A) when is_integer(A) -> A;
arity(A) when is_list(A) -> length(A).

loop(P, Acc) ->
    receive
        {trace, _, call, {M, F, A}, St} -> loop(P, [{{M, F, length(A)}, A, St} | Acc]);
        {done, P} -> P ! {events, lists:reverse(Acc)}
    end.
