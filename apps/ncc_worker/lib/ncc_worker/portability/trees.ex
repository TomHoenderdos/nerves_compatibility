defmodule NccWorker.Portability.Trees do
  @moduledoc """
  Item 5e of the precompiled judge refinements: a closure dependency's own
  source files are its verified Hex tarball's.

  The snapshot must be taken before any compile of the closure: Mix's own
  compilers write into a dependency's source dir (leex and yecc put the
  `.erl` they generate in `src/`), so a snapshot after one refuses what the
  toolchain wrote. Callers take it right after the `deps.get` that fetched
  the closure (`NccWorker.Portability.tree_snapshot/2`) and pass it to
  `NccWorker.Portability.run/3` as `trees:`; `run/3` takes it itself only
  when the build dir holds none of the closure's apps, and otherwise checks
  nothing and cannot judge.

  Before the traced compile, `snapshot/5` checks every locked dependency
  under `deps/` that has a verified tarball: the regular files on disk must
  be exactly the members of the tarball's `contents.tar.gz` (inflated by
  `Rebar.contents_tar/1`, under its 64 MiB cap), byte for byte (sha256).
  Left out, at the source dir's root only: the files Hex writes there
  (`.hex`, `hex_metadata.config`, observed on a real `mix deps.get` under
  Hex 2.x), and a `_build` directory the tarball does not carry, which
  rebar3 writes into a dependency's source dir when Mix builds it (its
  `rebar_compiler_erl/source.dag`). Neither is in the Hex file list, so
  no read of them is allowed anyway (`Context.readable?/2`). A difference
  is a refusal of the build, "dependency tree differs from its tarball".

  The judge then re-checks only what the compile read (`check_read/4`): a
  read regular file must still be its member, a probed directory a
  member's ancestor, and a directory listing (a wildcard, `list_dir`) one
  level deep must be the members' names at that level.
  A tree that matched before the compile and no longer does at judge time
  is not a refusal (the files the compile saw were the tarball's when the
  check ran): `NccWorker.Portability.Events` makes it could-not-judge.

  Not checked, so today's verdict stands ("unverified"): a natively built
  dependency (its build writes into its own source dir, and its source
  reads are restricted already), one without a verified tarball or source
  dir, a tarball that is unreadable, has links or too many members, a tree
  with more than 64 MiB of regular files, and every dependency checked once
  the snapshot's time budget (default 60 s) is spent.
  """

  alias NccWorker.HexCache
  alias NccWorker.Portability.Rebar

  @max_members 20_000
  @max_tree_bytes 64 * 1024 * 1024
  @budget_ms 60_000
  # Written by `mix deps.get` at the root of `deps/<d>` (Hex 2.x, Elixir
  # 1.19 and 1.20): nothing else.
  @hex_extras ~w(.hex hex_metadata.config)

  @type members :: %{String.t() => String.t()}
  @type tree :: {:ok, members()} | {:differs, String.t()} | {:unverified, String.t()}

  @doc """
  Each locked app's tree, checked against its verified tarball (see the
  moduledoc). `releases` is `%{app => %{name, version, checksum}}`, the
  lock snapshot; `hex_home` the run's Hex cache; `native` the apps that
  build native code. Options (tests): `budget_ms:`, `max_tree_bytes:`.
  """
  @spec snapshot(String.t(), map(), String.t() | nil, [String.t()], keyword()) ::
          %{String.t() => tree()}
  def snapshot(project_dir, releases, hex_home, native, opts \\ [])

  def snapshot(project_dir, releases, hex_home, native, opts)
      when is_binary(project_dir) and is_map(releases) and is_list(native) do
    deadline = now() + Keyword.get(opts, :budget_ms, @budget_ms)
    limits = %{bytes: Keyword.get(opts, :max_tree_bytes, @max_tree_bytes), deadline: deadline}

    releases
    |> Enum.sort()
    |> Map.new(fn {app, release} ->
      dest = Path.join([project_dir, "deps", app])

      tree =
        cond do
          app in native -> {:unverified, "native build"}
          now() >= deadline -> {:unverified, "no time left"}
          true -> tree(dest, tarball(hex_home, release), limits)
        end

      {app, tree}
    end)
  end

  def snapshot(_project_dir, _releases, _hex_home, _native, _opts), do: %{}

  defp tarball(home, %{name: name, version: version, checksum: sum})
       when is_binary(home) and home != "" and is_binary(name) and is_binary(version) and
              is_binary(sum),
       do: HexCache.package_tarball(home, name, version, sum)

  defp tarball(_home, _release), do: nil

  defp tree(_dest, nil, _limits), do: {:unverified, "no verified tarball"}

  defp tree(dest, tarball, limits) do
    if dir?(dest) do
      with {:ok, members} <- members(tarball), do: compare(dest, members, limits)
    else
      {:unverified, "no source dir"}
    end
  end

  # The run's own `deps/<d>`.
  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(dest), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(dest))

  @doc """
  The snapshot for a lock `later_releases` that replaced `first_releases`
  after a compile (optional dependencies fetched after the first host
  compile): an app locked the same in both keeps its `first` tree, taken
  before any compile wrote into it; any other app takes its `later` one,
  taken after the second `deps.get` and before the compile that builds it.
  An app whose release changed was refetched over a tree a compile may have
  written into, so its `later` difference is "unverified", never a refusal.
  """
  @spec merge(map(), map(), map(), map()) :: %{String.t() => tree()}
  def merge(first, first_releases, later, later_releases) do
    Map.new(later_releases, fn {app, release} ->
      cond do
        Map.get(first_releases, app) == release and Map.has_key?(first, app) ->
          {app, first[app]}

        Map.has_key?(first_releases, app) ->
          {app, refetched(Map.get(later, app, {:unverified, "no snapshot"}))}

        true ->
          {app, Map.get(later, app, {:unverified, "no snapshot"})}
      end
    end)
  end

  defp refetched({:differs, detail}), do: {:unverified, "refetched after a compile: " <> detail}
  defp refetched(tree), do: tree

  @doc "The regular-file members of a Hex tarball's `contents.tar.gz`, by sha256."
  @spec members(binary()) :: {:ok, members()} | {:unverified, String.t()}
  def members(tarball) when is_binary(tarball) do
    with {:ok, tar} <- Rebar.contents_tar(tarball),
         {:ok, table} <- :erl_tar.table({:binary, tar}, [:verbose]),
         :ok <- plain_table(table),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      {:ok, Map.new(files, fn {name, body} -> {member_name(name), sha256(body)} end)}
    else
      {:unverified, _why} = unverified -> unverified
      _ -> {:unverified, "tarball unreadable"}
    end
  rescue
    _ -> {:unverified, "tarball unreadable"}
  end

  defp plain_table(table) when length(table) > @max_members, do: {:unverified, "too many members"}

  defp plain_table(table) do
    if Enum.all?(table, &(elem(&1, 1) in [:regular, :directory])),
      do: :ok,
      else: {:unverified, "tarball has links"}
  end

  defp member_name(name), do: name |> List.to_string() |> String.trim_leading("./")

  defp compare(dest, members, limits) do
    case walk(dest, "", extras(members), {%{}, 0}, limits) do
      {:ok, {disk, _bytes}} -> diff(disk, members)
      {:link, rel} -> {:differs, "link " <> rel}
      :too_large -> {:unverified, "tree too large"}
      :too_slow -> {:unverified, "no time left"}
      :error -> {:unverified, "tree unreadable"}
    end
  end

  defp diff(disk, members) do
    extra = Enum.sort(Map.keys(disk) -- Map.keys(members))
    missing = Enum.sort(Map.keys(members) -- Map.keys(disk))
    modified = for {rel, sha} <- Enum.sort(disk), Map.get(members, rel, sha) != sha, do: rel

    cond do
      extra != [] -> {:differs, "extra file " <> hd(extra)}
      missing != [] -> {:differs, "missing file " <> hd(missing)}
      modified != [] -> {:differs, "modified file " <> hd(modified)}
      true -> {:ok, members}
    end
  end

  # The root names the comparison leaves out: Hex's own files, and `_build`
  # unless the tarball carries one.
  defp extras(members) do
    if Enum.any?(Map.keys(members), &(&1 == "_build" or String.starts_with?(&1, "_build/"))),
      do: @hex_extras,
      else: ["_build" | @hex_extras]
  end

  # Regular files under `dest/rel`, relative to `dest`, by sha256; `lstat`,
  # so a link is reported, never followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp walk(dest, rel, extras, acc, limits) do
    case File.ls(Path.join(dest, rel)) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, acc}, fn name, {:ok, acc} ->
          case walk_entry(
                 dest,
                 join(rel, name),
                 rel == "" and name in extras,
                 extras,
                 acc,
                 limits
               ) do
            {:ok, _acc} = ok -> {:cont, ok}
            other -> {:halt, other}
          end
        end)

      {:error, _reason} ->
        :error
    end
  end

  defp walk_entry(_dest, _rel, true, _extras, acc, _limits), do: {:ok, acc}

  # sobelow_skip ["Traversal.FileModule"]
  defp walk_entry(dest, rel, false, extras, {files, _bytes} = acc, limits) do
    path = Path.join(dest, rel)

    cond do
      now() >= limits.deadline -> :too_slow
      map_size(files) >= @max_members -> :too_large
      true -> entry(File.lstat(path), dest, rel, path, extras, acc, limits)
    end
  end

  defp entry({:ok, %File.Stat{type: :directory}}, dest, rel, _path, extras, acc, limits),
    do: walk(dest, rel, extras, acc, limits)

  defp entry({:ok, %File.Stat{type: :regular, size: size}}, _, _, _, _, {_, bytes}, limits)
       when bytes + size > limits.bytes,
       do: :too_large

  defp entry({:ok, %File.Stat{type: :regular, size: size}}, _, rel, path, _, acc, _limits) do
    {files, bytes} = acc

    case file_sha256(path) do
      {:ok, sha} -> {:ok, {Map.put(files, rel, sha), bytes + size}}
      :error -> :error
    end
  end

  defp entry({:ok, _other}, _dest, rel, _path, _extras, _acc, _limits), do: {:link, rel}
  defp entry({:error, _reason}, _dest, _rel, _path, _extras, _acc, _limits), do: :error

  @doc """
  The judge-time re-check of one read under a dependency's source dir
  `dest`, `rel` relative to it (`""` for `dest` itself), whose tree matched
  `members` before the compile.

    * A listing (`listing?`) must be the direct children `list_dir` sees
      there now, one level deep (a subdirectory as `name/`), equal to what
      the members give at that level. Files a Mix compiler generated deeper
      (leex, yecc) do not change a listing above them.
    * A regular file must be its member, byte for byte.
    * A directory must be a member's ancestor (one made after the check is
      a change, though `File.dir?/1` only probed it).

  A path that is not there, and anything under the root names `snapshot/5`
  leaves out, is today's verdict, `:ok`.
  """
  @spec check_read(String.t(), String.t(), members(), boolean()) :: :ok | {:differs, String.t()}
  def check_read(dest, rel, members, true) do
    extras = extras(members)

    cond do
      root_extra?(rel, extras) -> :ok
      children(dest, rel, extras) == {:ok, member_children(members, rel)} -> :ok
      true -> {:differs, "listing " <> display(rel)}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  def check_read(dest, rel, members, false) do
    path = Path.join(dest, rel)

    cond do
      root_extra?(rel, extras(members)) ->
        :ok

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            if file_sha256(path) == {:ok, Map.get(members, rel)},
              do: :ok,
              else: {:differs, "read " <> display(rel)}

          {:ok, %File.Stat{type: :directory}} ->
            if rel == "" or Enum.any?(Map.keys(members), &under_rel?(&1, rel)),
              do: :ok,
              else: {:differs, "read " <> display(rel)}

          {:ok, _link_or_other} ->
            {:differs, "read " <> display(rel)}

          {:error, _reason} ->
            :ok
        end
    end
  end

  defp root_extra?(rel, extras) do
    case Path.split(rel) do
      [name | _] -> name in extras
      [] -> false
    end
  end

  # The members' names one level below `rel`, a directory as `name/`.
  defp member_children(members, rel) do
    for {path, _sha} <- members, under_rel?(path, rel), into: MapSet.new() do
      rest =
        if rel == "",
          do: path,
          else: binary_part(path, byte_size(rel) + 1, byte_size(path) - byte_size(rel) - 1)

      case String.split(rest, "/", parts: 2) do
        [name] -> name
        [dir, _below] -> dir <> "/"
      end
    end
  end

  # What `list_dir` of `dest/rel` gives now, a directory as `name/`; the
  # empty set when it is not a directory. `:error` when it cannot be read.
  # sobelow_skip ["Traversal.FileModule"]
  defp children(dest, rel, extras) do
    dir = Path.join(dest, rel)

    with true <- dir?(dir),
         {:ok, names} <- File.ls(dir),
         true <- length(names) <= @max_members do
      {:ok,
       for name <- names, not (rel == "" and name in extras), into: MapSet.new() do
         if dir?(Path.join(dir, name)), do: name <> "/", else: name
       end}
    else
      false -> if dir?(dir), do: :error, else: {:ok, MapSet.new()}
      _ -> :error
    end
  end

  defp under_rel?(_path, ""), do: true
  defp under_rel?(path, rel), do: String.starts_with?(path, rel <> "/")

  defp join("", name), do: name
  defp join(rel, name), do: rel <> "/" <> name

  defp display(""), do: "."
  defp display(rel), do: rel

  # sobelow_skip ["Traversal.FileModule"]
  defp file_sha256(path) do
    {:ok,
     path
     |> File.stream!(65_536)
     |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
     |> :crypto.hash_final()
     |> Base.encode16(case: :lower)}
  rescue
    _ -> :error
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp now, do: System.monotonic_time(:millisecond)
end
