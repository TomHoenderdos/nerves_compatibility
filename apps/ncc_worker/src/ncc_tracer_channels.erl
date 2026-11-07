-module(ncc_tracer_channels).
%% The primitives the compile-time trace watches (precompiled portability
%% spec, R1 channel table) and the short summary of one call that the tracer
%% writes when the call happens in user extent. Pure: no process, no I/O.
-export([patterns/0, classify/3, chars/1, term_bin/1]).

-define(READS, [{file, read_file}, {file, read_file_info}, {file, read_link_info},
                {file, read_link}, {file, read_link_all}, {file, list_dir},
                {file, list_dir_all}, {file, consult}, {prim_file, read_file},
                {prim_file, read_file_info}, {prim_file, read_link_info},
                {prim_file, list_dir}, {prim_file, list_dir_all}, {prim_file, read_link},
                {prim_file, read_link_all},
                {erl_prim_loader, get_file}, {erl_prim_loader, list_dir},
                {erl_prim_loader, read_file_info}]).
-define(WRITES, [{file, write_file}, {file, make_dir}, {file, write_file_info},
                 {file, change_mode}, {file, change_time}, {file, delete},
                 {file, del_dir}, {file, del_dir_r}, {prim_file, write_file},
                 {prim_file, make_dir}, {prim_file, write_file_info},
                 {prim_file, delete}, {prim_file, del_dir}]).
-define(WRITE_MODES, [write, append, exclusive, read_write]).

patterns() ->
    [{os, type, 0}, {os, version, 0}, {erlang, system_info, 1},
     {os, getenv, 0}, {os, getenv, 1}, {os, getenv, 2}, {os, env, 0},
     {init, get_argument, 1}, {init, get_arguments, 0}, {init, get_plain_arguments, 0},
     {erlang, open_port, 2}, {os, cmd, 1}, {os, cmd, 2},
     {os, find_executable, 1}, {os, find_executable, 2},
     {file, read_file, 1}, {file, read_file, 2}, {file, read_file_info, 1},
     {file, read_file_info, 2}, {file, read_link_info, 1}, {file, read_link_info, 2},
     {file, read_link, 1}, {file, read_link_all, 1}, {file, list_dir, 1},
     {file, list_dir_all, 1},
     {file, open, 2}, {file, consult, 1}, {file, get_cwd, 0}, {file, get_cwd, 1},
     {filelib, wildcard, 1}, {filelib, wildcard, 2},
     {prim_file, read_file, 1}, {prim_file, read_file_info, 1},
     {prim_file, read_file_info, 2}, {prim_file, list_dir, 1}, {prim_file, open, 2},
     {prim_file, read_link, 1}, {prim_file, get_cwd, 0},
     %% The link and directory reads behind File.lstat/read_link, which R4's
     %% mix.exs allowlist (File) relies on seeing, in every entry point.
     {prim_file, read_link_info, 1}, {prim_file, read_link_info, 2},
     {prim_file, read_link_all, 1}, {prim_file, list_dir_all, 1}, {prim_file, get_cwd, 1},
     %% Changing the working directory changes what every later relative
     %% path names, so the judge must see it.
     {file, set_cwd, 1}, {prim_file, set_cwd, 1},
     {erl_prim_loader, get_file, 1}, {erl_prim_loader, list_dir, 1},
     {erl_prim_loader, read_file_info, 1},
     {file, write_file, 2}, {file, write_file, 3}, {file, make_dir, 1},
     {file, rename, 2}, {file, copy, 2}, {file, copy, 3}, {file, make_symlink, 2},
     {file, make_link, 2}, {file, write_file_info, 2}, {file, write_file_info, 3},
     {file, change_mode, 2}, {file, change_time, 2}, {file, change_time, 3},
     {file, delete, 1}, {file, del_dir, 1}, {file, del_dir_r, 1},
     {prim_file, write_file, 2}, {prim_file, make_dir, 1}, {prim_file, rename, 2},
     {prim_file, make_symlink, 2}, {prim_file, make_link, 2},
     {prim_file, write_file_info, 2}, {prim_file, write_file_info, 3},
     {prim_file, delete, 1}, {prim_file, del_dir, 1}, {prim_file, copy, 3},
     {inet, gethostname, 0}, {inet, getifaddrs, 0}, {net_adm, localhost, 0},
     {gen_tcp, connect, 3}, {gen_tcp, connect, 4},
     {ssl, connect, 2}, {ssl, connect, 3}, {ssl, connect, 4},
     {httpc, request, 1}, {httpc, request, 2}, {httpc, request, 4}, {httpc, request, 5},
     {socket, open, 2}, {socket, open, 3}, {socket, open, 4},
     {code, root_dir, 0}, {code, lib_dir, 0}, {code, lib_dir, 1}, {code, lib_dir, 2},
     {code, priv_dir, 1}, {code, get_path, 0}, {application, loaded_applications, 0},
     {crypto, supports, 0}, {crypto, supports, 1}, {crypto, info_lib, 0},
     {crypto, info, 0}, {crypto, info_fips, 0},
     %% erlang:load_nif/2 is kept, but it is not reliably call-traceable (no
     %% pattern fires for it on OTP 28 or 29): the tracer's /proc/self/maps
     %% snapshots (NccWorker.Portability.MappedLibs) are what catch a NIF load.
     {erlang, load_nif, 2}, {erl_ddll, load, 2}, {erl_ddll, load_driver, 2},
     {erl_ddll, try_load, 3},
     {'Elixir.System', version, 0}, {'Elixir.System', build_info, 0},
     {'Elixir.Version', 'match?', 2}, {'Elixir.Version', 'match?', 3},
     {'Elixir.Version', compare, 2},
     {erlang, trace, 3}, {erlang, trace_pattern, 2}, {erlang, trace_pattern, 3},
     {erlang, system_flag, 2}, {erlang, suspend_process, 1},
     {erlang, suspend_process, 2},
     {trace, '_', '_'}, {dbg, '_', '_'}, {seq_trace, '_', '_'},
     %% The BIFs behind trace sessions: a package holding the session's weak
     %% handle (trace:session_info/1 lists it) can untrace or destroy it here.
     {erts_internal, trace, 3}, {erts_internal, trace, 4},
     {erts_internal, trace_pattern, 3}, {erts_internal, trace_pattern, 4},
     {erts_internal, trace_info, 3}, {erts_internal, trace_session_create, 3},
     {erts_internal, trace_session_destroy, 1},
     %% The tracer's own API and sentinel probe: the driver calls them from
     %% toolchain frames, a package calling them is recorded.
     {ncc_tracer, '_', '_'}, {ncc_tracer_probe, fire, 1},
     %% Unsticking is the first step of reloading a kernel module, which
     %% drops its trace patterns.
     {code, unstick_mod, 1}, {code, unstick_dir, 1},
     %% Reading another process's dictionary, stack or mailbox (where the
     %% driver keeps its token): the tracer's match spec for process_info/2
     %% fires only for those items.
     {erlang, process_info, 1}, {erlang, process_info, 2},
     {application, get_env, 1}, {application, get_env, 2}, {application, get_env, 3},
     {application, get_all_env, 0}, {application, get_all_env, 1}].

classify(M, F, Args) ->
    case specific(M, F, Args) of
        unknown -> generic(M, F, Args);
        Class -> Class
    end.

specific(code, F, [_]) when F =:= unstick_mod; F =:= unstick_dir -> {integrity, #{}};
specific(erlang, process_info, [_Pid]) -> {integrity, #{item => <<"all">>}};
specific(erlang, process_info, [_Pid, Item]) -> process_item(Item);
specific(os, type, []) -> {os_identity, #{}};
specific(os, version, []) -> {os_identity, #{}};
specific(erlang, system_info, [Key]) -> {os_identity, #{key => term_bin(Key)}};
specific(os, getenv, []) -> {env, #{}};
specific(os, getenv, [Name | _]) -> {env, #{name => chars(Name)}};
specific(os, env, []) -> {env, #{}};
specific(init, get_argument, [Name]) -> {env, #{name => term_bin(Name)}};
specific(init, F, []) when F =:= get_arguments; F =:= get_plain_arguments -> {env, #{}};
specific(erlang, open_port, [Name | _]) -> {programs, #{port => term_bin(Name)}};
specific(os, cmd, [Cmd | _]) -> {programs, #{cmd => chars(Cmd)}};
specific(os, find_executable, [Name | _]) -> {programs, #{name => chars(Name)}};
specific(M, open, [Path, Modes]) when M =:= file; M =:= prim_file -> open(Path, Modes);
specific(M, get_cwd, _) when M =:= file; M =:= prim_file -> {file_read, #{cwd => true}};
specific(M, set_cwd, [Dir]) when M =:= file; M =:= prim_file -> {cwd, #{path => chars(Dir)}};
specific(filelib, wildcard, [Pattern]) -> {file_read, #{path => wildcard_dir(Pattern, "")}};
specific(filelib, wildcard, [Pattern, Cwd]) -> {file_read, #{path => wildcard_dir(Pattern, Cwd)}};
specific(M, rename, [From, To]) when M =:= file; M =:= prim_file ->
    {file_write, #{path => chars(To), from => chars(From), from_kind => write}};
specific(M, copy, [From, To | _]) when M =:= file; M =:= prim_file ->
    {file_write, #{path => chars(copy_name(To)), from => chars(copy_name(From)), from_kind => read}};
specific(M, F, [_Existing, New])
  when (M =:= file orelse M =:= prim_file), (F =:= make_symlink orelse F =:= make_link) ->
    {file_write, #{path => chars(New)}};
specific(_M, _F, _Args) -> unknown.

generic(M, F, Args) ->
    case {lists:member({M, F}, ?READS), lists:member({M, F}, ?WRITES)} of
        {true, _} -> {file_read, #{path => first_path(Args)}};
        {_, true} -> {file_write, #{path => first_path(Args)}};
        _ -> by_module(M, F, Args)
    end.

by_module(M, _F, _Args) when M =:= inet; M =:= net_adm; M =:= gen_tcp; M =:= ssl;
                             M =:= httpc; M =:= socket ->
    {network, #{}};
by_module(code, F, []) -> {install, #{what => F}};
by_module(code, F, [App | _]) -> {install, #{what => F, app => App}};
by_module(application, loaded_applications, []) -> {install, #{what => loaded_applications}};
by_module(crypto, _F, _Args) -> {crypto, #{}};
by_module(erlang, load_nif, [Path | _]) -> {native, #{path => chars(Path)}};
by_module(erl_ddll, _F, [Path | _]) -> {native, #{path => chars(Path)}};
by_module('Elixir.System', _F, _Args) -> {elixir_version, #{}};
by_module('Elixir.Version', _F, [A, B | _]) ->
    {elixir_version, #{left => quoted_chars(A), right => quoted_chars(B)}};
by_module(erlang, system_flag, [Flag | _]) -> {integrity, #{flag => term_bin(Flag)}};
by_module(erlang, F, _Args) when F =:= trace; F =:= trace_pattern; F =:= suspend_process ->
    {integrity, #{}};
by_module(M, _F, _Args) when M =:= trace; M =:= dbg; M =:= seq_trace; M =:= ncc_tracer;
                             M =:= ncc_tracer_probe ->
    {integrity, #{}};
by_module(erts_internal, F, _Args) when F =:= trace; F =:= trace_pattern; F =:= trace_info;
                                       F =:= trace_session_create;
                                       F =:= trace_session_destroy ->
    {integrity, #{}};
by_module(application, get_env, [Key]) ->
    {config, #{app => null, key => term_bin(Key), key_name => atom_name(Key), atoms => false}};
by_module(application, get_env, [App, Key | _]) ->
    {config, #{app => term_bin(App), key => term_bin(Key), app_name => atom_name(App),
               key_name => atom_name(Key), atoms => is_atom(App) andalso is_atom(Key)}};
by_module(application, get_all_env, Args) ->
    {config, #{app => first_term(Args), app_name => first_atom_name(Args), all => true}};
by_module(_M, _F, _Args) -> unknown.

open(Path, Modes) ->
    List = case is_list(Modes) of true -> Modes; false -> [Modes] end,
    case lists:any(fun(Mode) -> lists:member(Mode, ?WRITE_MODES) end, List) of
        true -> {file_write, #{path => chars(Path)}};
        false -> {file_read, #{path => chars(Path)}}
    end.

%% The process_info/2 items that expose another process's state.
-define(PEEKS, [dictionary, backtrace, messages]).

process_item(Item) ->
    case lists:any(fun peek/1, case is_list(Item) of true -> Item; false -> [Item] end) of
        true -> {integrity, #{item => term_bin(Item)}};
        false -> unknown
    end.

peek({dictionary, _Key}) -> true;
peek(Item) -> lists:member(Item, ?PEEKS).

copy_name({Name, _Modes}) -> Name;
copy_name(Name) -> Name.

%% A version string or requirement, rendered with chars/1 and quoted the way
%% Elixir inspects a string, so a run through chars/1's binary path never
%% carries the <<"...">> wrapper term_bin/1 would print for it.
quoted_chars(X) ->
    case chars(X) of
        null -> null;
        B -> <<$", B/binary, $">>
    end.

first_path([Path | _]) -> chars(Path);
first_path([]) -> null.

first_term([Term | _]) -> term_bin(Term);
first_term([]) -> null.

%% The exact text of an atom (a compile_env item names apps and keys by it),
%% null for anything else. Only an existing atom is rendered: nothing here
%% creates one.
atom_name(A) when is_atom(A) -> atom_to_binary(A);
atom_name(_X) -> null.

first_atom_name([A | _]) -> atom_name(A);
first_atom_name([]) -> null.

%% The literal directory a wildcard starts from: everything before the first
%% glob character, cut back to a directory, joined to the wildcard's Cwd.
wildcard_dir(Pattern, Cwd) ->
    Literal = lists:takewhile(fun(C) -> not lists:member(C, "*?[{") end, to_list(Pattern)),
    Dir = case Literal =:= "" orelse lists:last(Literal) =:= $/ of
              true -> string:trim(Literal, trailing, "/");
              false -> filename:dirname(Literal)
          end,
    chars(join_cwd(to_list(Cwd), Dir)).

join_cwd("", Dir) -> Dir;
join_cwd(Cwd, Dir) ->
    case filename:pathtype(Dir) of
        absolute -> Dir;
        _ -> filename:join(Cwd, Dir)
    end.

to_list(X) when is_binary(X) -> unicode:characters_to_list(X);
to_list(X) when is_atom(X) -> atom_to_list(X);
to_list(X) when is_list(X) -> X;
to_list(_X) -> "".

chars(null) -> null;
chars(X) when is_atom(X) -> atom_to_binary(X);
chars(X) when is_binary(X); is_list(X) ->
    try unicode:characters_to_binary(filename:flatten(X)) of
        B when is_binary(B) -> B;
        _ -> term_bin(X)
    catch
        _:_ -> term_bin(X)
    end;
chars(X) -> term_bin(X).

term_bin(Term) ->
    case unicode:characters_to_binary(io_lib:format("~0tP", [Term, 10])) of
        B when is_binary(B) -> B;
        _ -> <<"?">>
    end.
