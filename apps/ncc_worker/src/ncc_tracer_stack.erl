-module(ncc_tracer_stack).
%% Stage-1 classification of one traced call by the stack it was made from
%% (precompiled portability spec, R1 steps 1-3). The tracer passes in which
%% modules are toolchain and whether the calling process is a user process.
-export([extent/4, frame/1, mfa_bin/3, dispatcher/1]).

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

extent(Stack, Depth, IsToolchain, ProcessIsUser) ->
    First = case strip(Stack) of
                [Frame | _] -> Frame;
                [] -> none
            end,
    case lists:search(fun({M, _, _, _}) -> not IsToolchain(M) end, Stack) of
        {value, User} -> {user, frame, First, User};
        false -> no_user_frame(Stack, Depth, First, ProcessIsUser)
    end.

no_user_frame(Stack, Depth, First, ProcessIsUser) ->
    case {First =/= none andalso dispatcher(First), length(Stack) >= Depth, ProcessIsUser} of
        {true, _, _} -> {user, dispatcher, First, none};
        {false, true, _} -> {user, truncated, First, none};
        {false, false, true} -> {user, lineage, First, none};
        {false, false, false} -> toolchain
    end.

strip([{M, _, _, _} | Rest] = Stack) ->
    case lists:member(M, ?WRAPPERS) of
        true -> strip(Rest);
        false -> Stack
    end;
strip([]) -> [].

dispatcher({M, F, _, _}) -> lists:member({M, base_name(F)}, ?DISPATCHERS).

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
