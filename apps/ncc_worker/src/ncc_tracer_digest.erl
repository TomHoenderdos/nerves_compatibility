-module(ncc_tracer_digest).
%% The digest of what a dependency's build dir publishes: every regular file
%% under its ebin and priv (a priv symlink is followed, as the archiver reads
%% it), by path relative to the build dir, by whether it is executable (the
%% file manifest keeps the mode) and by content. The tracer takes it when a
%% dependency's window closes; the judge takes it again before it judges,
%% and a build that changed in between is not judged (precompiled
%% portability spec, R3: no dependency is judged without a trace of its own
%% compile). Pure but for reading files; called from the tracer's untraced
%% collector and from the worker.
%%
%% ebin and priv themselves are followed wherever they point: Mix links a
%% dependency's priv to its source. A link below them is followed only when
%% it resolves inside the tree it is in (the real path of that ebin or priv);
%% one that leads out of it is an error, where the archiver would follow it.
%%
%% Bounded, because it runs inside the collector at every window close: at
%% most 100 000 files, and as many entries in one directory, 1 GiB, 64
%% directories deep (so a symlink loop ends), read in 1 MiB chunks, and done
%% within 60 s, below the driver's call timeout. Past any bound it is an
%% error, never a digest of part of the build; the judge treats an error as
%% a missing digest.
-export([dir/1, dir/2]).

-include_lib("kernel/include/file.hrl").

-define(MAX_FILES, 100000).
-define(MAX_BYTES, 1073741824).
-define(MAX_DEPTH, 64).
-define(MAX_LINK_HOPS, 40).
-define(CHUNK_BYTES, 1048576).
-define(TIMEOUT_MS, 60000).

%% tree: the real path of the ebin or priv being walked.
-record(lim, {max_files, max_bytes, chunk, deadline, before_read, tree}).

dir(Dir) -> dir(Dir, #{}).

%% Opts (tests): max_files, max_bytes, chunk_bytes, timeout_ms, and
%% before_read, a fun called with each file's path just before it is read.
dir(Dir, Opts) ->
    Lim = #lim{max_files = maps:get(max_files, Opts, ?MAX_FILES),
               max_bytes = maps:get(max_bytes, Opts, ?MAX_BYTES),
               chunk = maps:get(chunk_bytes, Opts, ?CHUNK_BYTES),
               deadline = now_ms() + maps:get(timeout_ms, Opts, ?TIMEOUT_MS),
               before_read = maps:get(before_read, Opts, fun(_) -> ok end)},
    try
        Root = name(Dir),
        {_, Files0} = walk_top(Root, <<"priv">>, walk_top(Root, <<"ebin">>, {0, []}, Lim), Lim),
        Files = lists:sort(Files0),
        ok = within_bytes(Files, Lim),
        hash(Files, crypto:hash_init(sha256), 0, Lim)
    catch
        throw:{digest, Reason} -> {error, Reason};
        _:Reason -> {error, Reason}
    end.

%% ebin or priv itself: followed when it is a link, empty when it is missing.
%% Acc is {files so far, [{Rel, Path, Exec, Size}]}.
walk_top(Root, Sub, Acc, Lim) ->
    Path = filename:join(Root, Sub),
    case file:read_file_info(Path) of
        {ok, Info} -> entry(Info, Path, Sub, 0, Acc, Lim#lim{tree = realpath(Path)});
        {error, enoent} -> Acc;
        {error, enotdir} -> Acc;
        {error, Why} -> throw({digest, {read, Why}})
    end.

entry(Info, Path, Rel, Depth, Acc, Lim) ->
    check_deadline(Lim),
    case {Info#file_info.type, Acc} of
        {directory, _} when Depth >= ?MAX_DEPTH -> throw({digest, too_deep});
        {directory, _} -> walk_dir(Path, Rel, Depth + 1, Acc, Lim);
        {regular, {N, _}} when N >= Lim#lim.max_files -> throw({digest, too_many_files});
        {regular, {N, Files}} ->
            Exec = case Info#file_info.mode band 8#111 of
                       0 -> 0;
                       _ -> 1
                   end,
            {N + 1, [{Rel, Path, Exec, Info#file_info.size} | Files]};
        _ -> Acc
    end.

walk_dir(Path, Rel, Depth, Acc, Lim) ->
    case file:list_dir_all(Path) of
        {ok, Names} when length(Names) > Lim#lim.max_files -> throw({digest, too_many_files});
        {ok, Names} ->
            lists:foldl(fun(Name, A) -> child(Path, Rel, Name, Depth, A, Lim) end, Acc, Names);
        {error, Why} -> throw({digest, {read, Why}})
    end.

child(Path, Rel, Name0, Depth, Acc, Lim) ->
    check_deadline(Lim),
    Name = name(Name0),
    Child = within_tree(filename:join(Path, Name), Lim),
    case file:read_file_info(Child) of
        {ok, Info} -> entry(Info, Child, <<Rel/binary, $/, Name/binary>>, Depth, Acc, Lim);
        %% A dangling link is no regular file.
        {error, enoent} -> Acc;
        {error, Why} -> throw({digest, {read, Why}})
    end.

%% The path to read Path by: a link must resolve inside the tree, and is
%% then read by its real path, so links never pile up in a path (the OS
%% gives up at a few dozen) and a looping one ends at the depth cap.
within_tree(Path, #lim{tree = Tree}) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            Real = realpath(Path),
            case lists:prefix(filename:split(Tree), filename:split(Real)) of
                true -> Real;
                false -> throw({digest, outside_tree})
            end;
        {ok, _} -> Path;
        {error, Why} -> throw({digest, {read, Why}})
    end.

%% The path with every link in it resolved, as far as it exists; at most
%% ?MAX_LINK_HOPS links, so a link cycle is an error.
realpath(Path) -> resolve(filename:split(filename:absname(Path)), [], 0).

resolve(_Parts, _Done, Hops) when Hops > ?MAX_LINK_HOPS -> throw({digest, too_many_links});
resolve([], Done, _Hops) -> filename:join(lists:reverse(Done));
resolve([<<".">> | Rest], Done, Hops) -> resolve(Rest, Done, Hops);
resolve([<<"..">> | Rest], [Top], Hops) -> resolve(Rest, [Top], Hops);
resolve([<<"..">> | Rest], [_ | Done], Hops) -> resolve(Rest, Done, Hops);
resolve([Part | Rest], Done, Hops) ->
    Path = filename:join(lists:reverse([Part | Done])),
    case file:read_link_all(Path) of
        {ok, Target0} ->
            Target = filename:split(name(Target0)),
            case filename:pathtype(name(Target0)) of
                absolute -> resolve(Target ++ Rest, [], Hops + 1);
                _ -> resolve(Target ++ Rest, Done, Hops + 1)
            end;
        {error, _} -> resolve(Rest, [Part | Done], Hops)
    end.

within_bytes(Files, #lim{max_bytes = Max}) ->
    case lists:sum([Size || {_, _, _, Size} <- Files]) > Max of
        true -> throw({digest, too_large});
        false -> ok
    end.

%% Each entry: <<byte_size(Rel):32, Rel, Exec:8, Size:64, Content>>.
hash([], Ctx, N, _Lim) ->
    {ok, binary:encode_hex(crypto:hash_final(Ctx), lowercase), N};
hash([{Rel, Path, Exec, Size} | Rest], Ctx0, N, Lim) ->
    Ctx = crypto:hash_update(Ctx0, <<(byte_size(Rel)):32, Rel/binary, Exec:8, Size:64>>),
    hash(Rest, content(Path, Size, Ctx, Lim), N + 1, Lim).

%% Exactly Size bytes, in chunks: a file that shrank or grew since it was
%% listed is not the file that was counted.
content(Path, Size, Ctx, #lim{before_read = BeforeRead} = Lim) ->
    _ = BeforeRead(Path),
    {ok, Fd} = file:open(Path, [read, raw, binary]),
    try chunks(Fd, Size, Ctx, Lim)
    after file:close(Fd)
    end.

chunks(Fd, 0, Ctx, _Lim) ->
    case file:read(Fd, 1) of
        eof -> Ctx;
        _ -> throw({digest, changed})
    end;
chunks(Fd, Left, Ctx, Lim) ->
    check_deadline(Lim),
    case file:read(Fd, min(Left, Lim#lim.chunk)) of
        {ok, Bin} -> chunks(Fd, Left - byte_size(Bin), crypto:hash_update(Ctx, Bin), Lim);
        eof -> throw({digest, changed});
        {error, Why} -> throw({digest, {read, Why}})
    end.

check_deadline(#lim{deadline = Deadline}) ->
    case now_ms() >= Deadline of
        true -> throw({digest, timeout});
        false -> ok
    end.

%% A path as a binary: list_dir_all/1 gives names as character lists, and as
%% raw binaries only when they do not decode.
name(Name) when is_binary(Name) -> Name;
name(Name) ->
    case unicode:characters_to_binary(Name) of
        Bin when is_binary(Bin) -> Bin;
        _ -> throw({digest, undecodable_name})
    end.

now_ms() -> erlang:monotonic_time(millisecond).
