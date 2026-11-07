-module(ncc_tracer_digest).
%% The digest of what a dependency's build dir publishes: every regular file
%% under its ebin and priv (a priv symlink is followed, as the archiver reads
%% it), by path relative to the build dir and by content. The tracer takes it
%% when a dependency's window closes; the judge takes it again before it
%% judges, and a build that changed in between is not judged (precompiled
%% portability spec, R3: no dependency is judged without a trace of its own
%% compile). Pure but for reading files; called from the tracer's untraced
%% collector and from the worker.
%%
%% Bounded, because it runs inside the collector at every window close: at
%% most 100 000 files and 1 GiB, walked no deeper than 64 directories (so a
%% symlink loop ends), read in 1 MiB chunks, and done within 60 s, below the
%% driver's call timeout. Past any bound it is an error, never a digest of
%% part of the build; the judge treats an error as a missing digest.
-export([dir/1, dir/2]).

-include_lib("kernel/include/file.hrl").

-define(MAX_FILES, 100000).
-define(MAX_BYTES, 1073741824).
-define(MAX_DEPTH, 64).
-define(CHUNK_BYTES, 1048576).
-define(TIMEOUT_MS, 60000).

-record(lim, {max_files, max_bytes, chunk, deadline}).

dir(Dir) -> dir(Dir, #{}).

%% Opts (tests): max_files, max_bytes, chunk_bytes, timeout_ms.
dir(Dir, Opts) ->
    Lim = #lim{max_files = maps:get(max_files, Opts, ?MAX_FILES),
               max_bytes = maps:get(max_bytes, Opts, ?MAX_BYTES),
               chunk = maps:get(chunk_bytes, Opts, ?CHUNK_BYTES),
               deadline = now_ms() + maps:get(timeout_ms, Opts, ?TIMEOUT_MS)},
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
%% Acc is {files so far, [{Rel, Path, Size}]}.
walk_top(Root, Sub, Acc, Lim) ->
    Path = filename:join(Root, Sub),
    case file:read_file_info(Path) of
        {ok, Info} -> entry(Info, Path, Sub, 0, Acc, Lim);
        {error, enoent} -> Acc;
        {error, enotdir} -> Acc;
        {error, Why} -> throw({digest, {read, Why}})
    end.

%% Entries below follow links as the archiver's File.regular?/1 does; a
%% link to a directory is walked, and the depth cap stops a loop.
entry(Info, Path, Rel, Depth, Acc, Lim) ->
    check_deadline(Lim),
    case {Info#file_info.type, Acc} of
        {directory, _} when Depth >= ?MAX_DEPTH -> throw({digest, too_deep});
        {directory, _} -> walk_dir(Path, Rel, Depth + 1, Acc, Lim);
        {regular, {N, _}} when N >= Lim#lim.max_files -> throw({digest, too_many_files});
        {regular, {N, Files}} -> {N + 1, [{Rel, Path, Info#file_info.size} | Files]};
        _ -> Acc
    end.

walk_dir(Path, Rel, Depth, Acc, Lim) ->
    case file:list_dir_all(Path) of
        {ok, Names} ->
            lists:foldl(fun(Name, A) -> child(Path, Rel, Name, Depth, A, Lim) end, Acc, Names);
        {error, Why} -> throw({digest, {read, Why}})
    end.

child(Path, Rel, Name0, Depth, Acc, Lim) ->
    Name = name(Name0),
    Child = filename:join(Path, Name),
    case file:read_file_info(Child) of
        {ok, Info} -> entry(Info, Child, <<Rel/binary, $/, Name/binary>>, Depth, Acc, Lim);
        %% A dangling link is no regular file.
        {error, enoent} -> Acc;
        {error, Why} -> throw({digest, {read, Why}})
    end.

within_bytes(Files, #lim{max_bytes = Max}) ->
    case lists:sum([Size || {_, _, Size} <- Files]) > Max of
        true -> throw({digest, too_large});
        false -> ok
    end.

hash([], Ctx, N, _Lim) ->
    {ok, binary:encode_hex(crypto:hash_final(Ctx), lowercase), N};
hash([{Rel, Path, Size} | Rest], Ctx0, N, Lim) ->
    Ctx = crypto:hash_update(Ctx0, <<(byte_size(Rel)):32, Rel/binary, Size:64>>),
    hash(Rest, content(Path, Size, Ctx, Lim), N + 1, Lim).

%% Exactly Size bytes, in chunks: a file that shrank or grew since it was
%% listed is not the file that was counted.
content(Path, Size, Ctx, Lim) ->
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
