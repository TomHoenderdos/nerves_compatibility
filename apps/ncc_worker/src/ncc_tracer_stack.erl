-module(ncc_tracer_stack).
%% Stage-1 classification of one traced call by the stack it was made from
%% (precompiled portability spec, R1 steps 1-3). The tracer passes in which
%% modules are toolchain and whether the calling process is a user process.
-export([extent/4, extent/5, frame/1, mfa_bin/3, dispatcher/1, dispatchers/0]).

-define(WRAPPERS, [os, 'Elixir.System', 'Elixir.Application', application, 'Elixir.File']).
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
    Stripped = strip(Stack),
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

strip([{M, _, _, _} | Rest] = Stack) ->
    case lists:member(M, ?WRAPPERS) of
        true -> strip(Rest);
        false -> Stack
    end;
strip([]) -> [].

dispatcher({M, F, _, _}) -> lists:member({M, base_name(F)}, ?DISPATCHERS).

dispatchers() -> [{M, list_to_atom(F)} || {M, F} <- ?DISPATCHERS].

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
