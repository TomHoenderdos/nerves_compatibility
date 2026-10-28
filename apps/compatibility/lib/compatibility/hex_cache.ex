defmodule Compatibility.HexCache do
  @moduledoc """
  The shared Hex tarball cache and its one writer.

  Every build mounts the cache read-only at `/hex-cache`
  (`Compatibility.Builder.Argv`). The worker seeds a per-run `HEX_HOME` from
  it, one symlink per cached tarball, and Hex downloads what is missing into
  that per-run dir (`NccWorker.HexCache`). `result.json` lists those
  downloads under `hex_cache.misses` and the cached tarballs the run's lock
  used under `hex_cache.hits`. After the container has exited, the host calls
  `promote/5` and `touch/3`; nothing else writes the cache.

  Only after the container has exited: everything under the run's work dir
  is the container's, and these checks hold only while nothing can change
  it between a check and the read.

  The layout is the one Hex itself uses under `HEX_HOME`:
  `<root>/packages/hexpm/<name>-<version>.tar`.

  ## What `promote/5` checks

  Once per call, every directory from the trusted work dir (`:trusted`) down
  to `source_dir` is a real directory by `File.lstat/1`: the container could
  have made `hex-home`, `packages` or `hexpm` a link to anywhere the host can
  read. A link there refuses every miss of the call. Then, per miss:

    1. The name and version are Hex's (`pair/1`): a lowercase package name
       and a version `Version.parse/1` accepts. Every path below is built from
       those two, never from a path the worker reported.
    2. The run's file is a regular file with one link and at most
       `:max_bytes` (16 MiB, hex_core's tarball limit), by `File.lstat/1`.
    3. Hex publishes an outer checksum for the release (`lookup`, called
       with the name and version; both hosts read the signed registry). An
       unknown release is refused; any other lookup failure, a rate limit
       included, skips this miss and every later one in the call, since that
       is Hex being unreachable, not the build's fault. A lookup must answer
       within `lookup_timeout_ms/0`, and the budget is checked again once it
       has, so a call overruns its budget by at most `max_overrun_ms/0`.
    4. The SHA-256 of the bytes read equals that checksum. The checksum the
       worker reported is never used. Because what is written is exactly the
       bytes that were hashed, a file swapped after the `lstat` can only ever
       land the tarball Hex serves for that release.
    5. `<root>/packages` and `<root>/packages/hexpm` are real directories
       (created when absent, never followed through a symlink). The bytes go
       to a fresh temporary file there (`O_EXCL`), mode `0644`, which is then
       renamed over `<name>-<version>.tar`. A reader sees the old file or the
       new one, never a partial one. An existing entry is replaced: the run
       downloaded the tarball because Hex rejected or lacked the cached one.

  Seeding from the cache stays safe even without these checks: Hex only uses
  a cached tarball whose outer checksum matches its signed registry, and
  re-downloads one that does not. They keep the cache to what Hex serves, so
  a build cannot fill it with junk or make every later build download again.
  """

  require Logger

  @max 256
  @budget_ms 60_000
  @lookup_timeout_ms 10_000
  # A 16 MiB read, hash and write on a local disk, generously.
  @read_slack_ms 5_000
  @max_bytes 16 * 1024 * 1024
  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @sha ~r/\A[0-9a-f]{64}\z/

  @type lookup :: (String.t(), String.t() -> {:ok, String.t()} | {:error, term()})
  @type counts :: %{
          promoted: non_neg_integer(),
          refused: non_neg_integer(),
          skipped: non_neg_integer(),
          ignored: non_neg_integer()
        }

  @doc """
  The default wall-clock budget of one `promote/5` call. Exposed so the
  portal's Oban config test can keep `Lifeline`'s `rescue_after` above a
  build's whole worst case.
  """
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  @doc """
  How long one checksum lookup may take, connect and receive together: the
  callers' HTTP timeouts are set from this.
  """
  @spec lookup_timeout_ms() :: pos_integer()
  def lookup_timeout_ms, do: @lookup_timeout_ms

  @doc """
  How far past `budget_ms/0` one `promote/5` call can run: one lookup that
  started just before the deadline, plus the read and write of the miss
  being considered then. Nothing starts after the deadline.
  """
  @spec max_overrun_ms() :: pos_integer()
  def max_overrun_ms, do: @lookup_timeout_ms + @read_slack_ms

  @doc """
  The `{name, version}` pairs a run's `result.json` says it locked: the
  package under test, the run's `deps_lock` and every system's own
  `deps_lock`. `touch/3` refreshes only these.
  """
  @spec locked_pairs(term()) :: MapSet.t({String.t(), String.t()})
  def locked_pairs(%{} = result) do
    package =
      case result["package"] do
        %{"name" => name, "version" => version} -> [{name, version}]
        _ -> []
      end

    systems =
      case result["systems"] do
        %{} = systems -> Enum.flat_map(Map.values(systems), &system_lock/1)
        _ -> []
      end

    (package ++ lock_pairs(result["deps_lock"]) ++ systems)
    |> Enum.filter(fn {name, version} -> is_binary(name) and is_binary(version) end)
    |> MapSet.new()
  end

  def locked_pairs(_result), do: MapSet.new()

  defp system_lock(%{"deps_lock" => lock}), do: lock_pairs(lock)
  defp system_lock(_system), do: []

  defp lock_pairs(%{} = lock) do
    Enum.flat_map(lock, fn
      {name, %{"version" => version}} -> [{name, version}]
      _ -> []
    end)
  end

  defp lock_pairs(_lock), do: []

  @doc "The file name Hex caches a release's tarball under."
  @spec tarball_name(String.t(), String.t()) :: String.t()
  def tarball_name(name, version), do: "#{name}-#{version}.tar"

  @doc "The directory `<root>/packages/hexpm` that holds the cached tarballs."
  @spec packages_dir(Path.t()) :: Path.t()
  def packages_dir(root), do: Path.join([root, "packages", "hexpm"])

  @doc """
  `{:ok, {name, version}}` for a `%{"name", "version"}` map naming a release
  the way Hex does, `:error` for anything else.
  """
  @spec pair(term()) :: {:ok, {String.t(), String.t()}} | :error
  def pair(%{"name" => name, "version" => version}) when is_binary(name) and is_binary(version) do
    with true <- Regex.match?(@name, name),
         {:ok, _} <- Version.parse(version) do
      {:ok, {name, version}}
    else
      _ -> :error
    end
  end

  def pair(_entry), do: :error

  @doc """
  Promotes the misses a run reported from `source_dir` (the run's own
  `packages/hexpm`, a host path) into the cache at `root`. `misses` is the
  untrusted `hex_cache.misses` value; anything but a list promotes nothing.
  `opts[:trusted]` (required) is the run's work dir, which the host created:
  `source_dir` must lie below it, through real directories only.

  Options: `:max` (default 256) misses considered per call, the rest counted
  as ignored; `:max_bytes` (default 16 MiB); `:budget_ms` (default
  `budget_ms/0`), after which the misses not yet considered are skipped: the
  caller holds a build slot.
  """
  @spec promote(term(), Path.t(), Path.t(), lookup(), keyword()) :: counts()
  def promote(misses, source_dir, root, lookup, opts \\ [])

  def promote(misses, source_dir, root, lookup, opts)
      when is_list(misses) and is_function(lookup, 2) do
    {kept, extra} = Enum.split(misses, Keyword.get(opts, :max, @max))

    ctx = %{
      source: source_dir,
      root: root,
      lookup: lookup,
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)
    }

    counts =
      case real_path_below(Keyword.fetch!(opts, :trusted), source_dir) do
        :ok ->
          {counts, _seen, _hex} =
            Enum.reduce(kept, {zero(), MapSet.new(), :up}, &step(&1, &2, ctx))

          counts

        {:error, why} ->
          Logger.warning("Hex cache misses from #{source_dir} refused: #{why}")
          %{zero() | refused: length(kept)}
      end

    %{counts | ignored: counts.ignored + length(extra)}
  end

  def promote(_misses, _source_dir, _root, _lookup, _opts), do: zero()

  @doc """
  Sets the access and modification times of the cached tarballs a run used
  (`hex_cache.hits`) to now, and returns how many it touched. The cache is
  read-only in a build, so reading a tarball there no longer moves its atime,
  and `Portal.Workers.Sweep` evicts by last use. Only a regular file in real
  directories is touched, and only for a pair in `locked`
  (`locked_pairs/1`): a hit is the container's word, and a run could
  otherwise name every cached release to keep it from eviction.
  """
  @spec touch(term(), Path.t(), MapSet.t({String.t(), String.t()})) :: non_neg_integer()
  def touch(hits, root, locked) when is_list(hits) do
    if real_dirs?(root),
      do: hits |> Enum.take(@max) |> Enum.count(&touch_hit(&1, root, locked)),
      else: 0
  end

  def touch(_hits, _root, _locked), do: 0

  defp zero, do: %{promoted: 0, refused: 0, skipped: 0, ignored: 0}

  defp step(miss, {counts, seen, hex}, ctx) do
    case pair(miss) do
      {:ok, pair} -> step_pair(pair, {counts, seen, hex}, ctx)
      :error -> {bump(counts, refuse_malformed(miss)), seen, hex}
    end
  end

  defp step_pair(pair, {counts, seen, hex}, ctx) do
    if MapSet.member?(seen, pair) do
      {bump(counts, :ignored), seen, hex}
    else
      {outcome, hex} = consider(pair, hex, ctx)
      {bump(counts, outcome), MapSet.put(seen, pair), hex}
    end
  end

  defp refuse_malformed(miss) do
    Logger.warning("Hex cache miss #{show(miss)} is not a Hex release; refused")
    :refused
  end

  defp touch_hit(hit, root, locked) do
    with {:ok, {name, version}} <- pair(hit),
         true <- MapSet.member?(locked, {name, version}),
         path = Path.join(packages_dir(root), tarball_name(name, version)),
         {:ok, %File.Stat{type: :regular}} <- lstat(path) do
      touch_file(path) == :ok
    else
      _ -> false
    end
  end

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp consider(_pair, :down, _ctx), do: {:skipped, :down}

  defp consider({name, version} = pair, :up, %{deadline: deadline} = ctx) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.info(
        "Hex cache misses from #{name} #{version} on not promoted: the time budget is spent"
      )

      {:skipped, :down}
    else
      check_and_install(pair, ctx)
    end
  end

  defp check_and_install({name, version} = pair, ctx) do
    source = Path.join(ctx.source, tarball_name(name, version))

    with :ok <- check_source(source, ctx.max_bytes),
         {:ok, expected} <- published(pair, ctx.lookup),
         :ok <- in_time(name, version, ctx),
         {:ok, bytes} <- read(source, ctx.max_bytes),
         :ok <- same_checksum(bytes, expected) do
      {install(pair, bytes, ctx.root), :up}
    else
      {:refused, why} ->
        Logger.warning("Hex cache miss #{name} #{version} #{why}; refused")
        {:refused, :up}

      :late ->
        {:skipped, :down}

      {:hex_down, reason} ->
        Logger.info(
          "Hex cache misses from #{name} #{version} on not promoted: " <>
            "Hex.pm checksum lookup returned #{show(reason)}"
        )

        {:skipped, :down}
    end
  end

  # The lookup may have taken until past the deadline; then nothing more.
  defp in_time(name, version, ctx) do
    if System.monotonic_time(:millisecond) < ctx.deadline do
      :ok
    else
      Logger.info(
        "Hex cache misses from #{name} #{version} on not promoted: the time budget is spent"
      )

      :late
    end
  end

  # Every directory from `trusted` down to `dir`, by lstat. `trusted` itself
  # is the host's; `dir` must be below it.
  defp real_path_below(trusted, dir) do
    trusted = Path.expand(trusted)
    dir = Path.expand(dir)

    case Path.relative_to(dir, trusted) do
      ^dir ->
        {:error, "#{dir} is not below #{trusted}"}

      relative ->
        relative
        |> Path.split()
        |> Enum.scan(trusted, &Path.join(&2, &1))
        |> Enum.find_value(:ok, &not_real_dir/1)
    end
  end

  defp not_real_dir(path) do
    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> nil
      _other -> {:error, "#{Path.basename(path)} is not a real directory"}
    end
  end

  # Step 2.
  defp check_source(source, max_bytes) do
    case lstat(source) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size}} when size <= max_bytes -> :ok
      {:ok, %File.Stat{type: :regular, links: 1}} -> {:refused, "is over #{max_bytes} bytes"}
      {:ok, %File.Stat{type: :regular}} -> {:refused, "is hardlinked"}
      {:ok, %File.Stat{type: type}} -> {:refused, "is not a regular file (#{type})"}
      {:error, reason} -> {:refused, "cannot be read (#{inspect(reason)})"}
    end
  end

  # Step 3.
  defp published({name, version}, lookup) do
    case lookup.(name, version) do
      {:ok, checksum} when is_binary(checksum) ->
        checksum = String.downcase(checksum)

        if Regex.match?(@sha, checksum),
          do: {:ok, checksum},
          else: {:hex_down, {:malformed_checksum, checksum}}

      {:error, :unknown_release} ->
        {:refused, "is not a release Hex.pm publishes"}

      other ->
        {:hex_down, other}
    end
  end

  # The size was checked by `lstat`; reading one byte more than the cap
  # catches a file that grew since.
  # `source` is the run's own scratch dir joined with a validated tarball name.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(source, max_bytes) do
    case File.open(source, [:read, :raw, :binary], &IO.binread(&1, max_bytes + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= max_bytes -> {:ok, bytes}
      {:ok, :eof} -> {:ok, ""}
      {:ok, bytes} when is_binary(bytes) -> {:refused, "is over #{max_bytes} bytes"}
      other -> {:refused, "cannot be read (#{show(other)})"}
    end
  end

  # Step 4.
  defp same_checksum(bytes, expected) do
    if :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == expected,
      do: :ok,
      else: {:refused, "does not hash to the checksum Hex.pm publishes"}
  end

  # Step 5.
  # `root` is the operator's cache root; the file name is built from a
  # validated pair and the temporary name is host random.
  # sobelow_skip ["Traversal.FileModule"]
  defp install({name, version}, bytes, root) do
    dir = packages_dir(root)
    dest = Path.join(dir, tarball_name(name, version))
    tmp = Path.join(dir, ".ncc-promote-#{Base.encode16(:crypto.strong_rand_bytes(8))}.tmp")

    with :ok <- ensure_real_dirs(root),
         :ok <- File.write(tmp, bytes, [:exclusive, :raw]),
         :ok <- File.chmod(tmp, 0o644),
         :ok <- File.rename(tmp, dest) do
      :promoted
    else
      error ->
        _ = File.rm(tmp)
        Logger.warning("Could not promote Hex tarball #{name} #{version}: #{why(error)}")
        :skipped
    end
  end

  # The root is the operator's and may itself be a symlink to another disk;
  # only what sits below it is checked.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_real_dirs(root) do
    with :ok <- File.mkdir_p(root), do: ensure_below(root)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_below(root) do
    Enum.reduce_while([Path.join(root, "packages"), packages_dir(root)], :ok, fn dir, :ok ->
      case ensure_dir(dir) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A missing dir is created; one another promotion created meanwhile must
  # still be real.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_dir(dir) do
    case lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with {:error, :eexist} <- File.mkdir(dir), do: ensure_real_dir(dir)

      _other ->
        {:error, {:not_a_real_directory, dir}}
    end
  end

  defp ensure_real_dir(dir) do
    case lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, {:not_a_real_directory, dir}}
    end
  end

  defp why({:error, {:not_a_real_directory, dir}}),
    do: "#{Path.basename(dir)} in the Hex cache is not a real directory"

  defp why(error), do: show(error)

  defp real_dirs?(root) do
    Enum.all?(
      [Path.join(root, "packages"), packages_dir(root)],
      &match?({:ok, %File.Stat{type: :directory}}, lstat(&1))
    )
  end

  # The path is a regular file in the operator's cache, just checked by lstat.
  # sobelow_skip ["Traversal.FileModule"]
  defp touch_file(path), do: File.touch(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path), do: File.lstat(path)

  # Container-chosen terms reach the log only through here, bounded.
  defp show(term), do: term |> inspect(limit: 5, printable_limit: 80) |> String.slice(0, 200)
end
