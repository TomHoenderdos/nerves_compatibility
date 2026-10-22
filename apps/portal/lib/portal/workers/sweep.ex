defmodule Portal.Workers.Sweep do
  @moduledoc """
  Oban worker (queue `:ingest`) that reclaims disk left behind by builds which
  died without running any Elixir.

  `Portal.Workers.Build` cleans up on every path it can reach — a returned error,
  and since `ecc3408` an exception too. None of that helps when the node is
  killed mid-build, which is what every deploy during a build does. On
  2026-08-31 that leak filled the 193G disk and kept the build host down for four
  days: `IO.binwrite/2` raised `:enospc`, the scratch dir survived, and each
  crash made the next one more likely.

  This worker is the backstop for the case where no code runs at all:

    * orphaned scratch trees (~3.5G each) whose build is long over
    * `build_cache` slugs for worker images that no longer exist
    * `.tmp.<hex>` staging trees inside live slugs, abandoned by
      `NccWorker.BuildCache.store_entry/2` when the container was killed
      between its `cp -a` and its `File.rename/2`

  It leaves `nerves_cache` alone: that is bounded by the number of Nerves
  systems rather than by time, and evicting one costs a several-hundred-megabyte
  re-download in the middle of a build. `hex_cache/packages` it keeps under a
  size bound (`hex_cache_max_bytes`, `NCC_HEX_CACHE_MAX_GB`): the cache is
  read-write inside every build container, so a package that depends on
  everything on Hex could otherwise fill the disk. An evicted tarball is simply
  fetched again. Every regular file under `packages/` counts, whatever its name,
  and the least recently used goes first, by `max(atime, mtime)`: Hex does not
  rewrite a cached tarball on a cache hit (a 304), so mtime alone is
  first-download order, while `relatime` still moves atime at least daily — fine
  resolution for an hourly sweep. A timestamp in the future counts as the epoch,
  so a hostile file cannot push every real tarball out ahead of itself. Nothing
  used in the last two hours (the build wall clock) is evicted, even over the
  bound. At the cache root, regular files other than `cache.ets` and
  `hex.config` go once older than the scratch max age.

  The hex sweep runs only while no build container (`ncc-*`) is running, and
  does nothing if docker cannot say. Builds are the only writers of
  `/hex-cache`, and a concurrent writer could otherwise race every
  lstat-then-delete here. The lookup is repeated after the walk, just before
  the first deletion. The guarantee is exactly "no build was running when the
  walk started and when deletion started": a build starting during the
  deletions themselves is not excluded, and is left to the lstat checks.

  Everything under `/hex-cache` is attacker-controlled, the cache root and
  `packages/` included, so the hex sweep never follows a symlink: both must be
  real directories by `File.lstat/2`, and nothing but a regular file is ever
  removed.

  ## Why queue `:ingest`

  Only the build host has these directories, and it is the only host running
  `:ingest`. `:maintenance` runs on the *web* host, where this would find no
  scratch root and report a clean disk forever. `:builds` has a limit of 3 and a
  two-hour wall clock, so a sweep could queue behind three long builds — starving
  exactly when the disk is most likely to be full.

  `Oban.Plugins.Cron` inserts only on the leader, but the inserted row carries
  this worker's queue, so it runs on the build host whichever node leads.
  """

  use Oban.Worker,
    # A failed sweep waits for the next hourly tick rather than retry-storming.
    #
    # `period: :infinity` + `:incomplete` is "never enqueue a sweep while one is
    # still outstanding", which is what we want and is unambiguous at the hourly
    # boundary — a finite period equal to the cron interval races with it. The
    # `du -sk` walks over multi-gigabyte trees make a slow sweep realistic, and
    # two of them would both try to delete the same directories.
    #
    # A sweep stranded `executing` by a dead node would block every later one
    # forever, except that `Oban.Plugins.Lifeline` discards it after three hours
    # (it is past `max_attempts`), and `discarded` is not an incomplete state.
    queue: :ingest,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias Portal.Builder
  alias Portal.Repo

  # 2h hard docker wall clock (`Portal.Builder.total_timeout_ms/0`) plus an hour
  # of margin for the ingest handoff.
  @default_max_age_ms :timer.hours(3)

  # A slug written moments ago by a build whose job row has not landed yet must
  # not be swept out from under it. A week is far longer than that needs.
  @cache_grace_ms :timer.hours(24 * 7)

  # Everything Oban has not finished with. A job in one of these states may still
  # read the directory its args name.
  @live_states ["available", "scheduled", "executing", "retryable"]

  @staging_pattern ~r/\.tmp\.[0-9a-f]+$/

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run()

  @doc """
  Reclaim orphaned scratch trees, dead build-cache slugs, and staging leftovers.

  Every input is an option so tests need neither docker, nor a clock, nor a real
  disk:

    * `:now_ms` — defaults to `System.system_time(:millisecond)`
    * `:scratch_root` / `:build_cache` / `:hex_cache` — default to the
      `Portal.Builder` config
    * `:max_age_ms` — scratch retention (and hex cache root junk), defaults to 3h
    * `:hex_cache_max_bytes` — hex cache retention, defaults to 20 GiB
    * `:live_run_ids` — `MapSet` of sanitized run ids with a live ingest job
    * `:running_containers` — `MapSet` of docker container names, `:error`
      for a failed docker lookup, or a zero-arity function returning either
      (called for each lookup)
    * `:current_digest` — digest the worker image resolves to right now
    * `:dry_run` — report what would go, delete nothing

  Always returns `:ok`. A sweep that cannot do its job logs and reclaims
  nothing; it never fails the Oban job, because there is no retry that would
  help and a red job row would bury the log line that says what went wrong.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    scratch = sweep_scratch(opts)
    cache = sweep_build_cache(opts)
    hex = sweep_hex_cache(opts)

    total = [scratch, cache, hex] |> Enum.reduce(empty(), &add/2)

    Logger.info(
      "Sweep reclaimed #{total.count} entries / #{mb(total.bytes)} MB " <>
        "(scratch #{scratch.count}, build-cache #{cache.count}, hex #{hex.count})"
    )

    :ok
  end

  # ── Scratch ────────────────────────────────────────────────────────────────

  defp sweep_scratch(opts) do
    root = Keyword.get_lazy(opts, :scratch_root, &Builder.scratch_root/0)
    now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
    max_age = Keyword.get(opts, :max_age_ms, configured_max_age_ms())

    with {:ok, names} <- list_dir(root),
         {:ok, live} <- live_run_ids(opts) do
      containers = scratch_containers(opts)

      names
      |> Enum.filter(&scratch_dead?(&1, now, max_age, live, containers))
      |> Enum.map(&Path.join(root, &1))
      |> delete_all(opts, "scratch")
    else
      _ -> empty()
    end
  end

  # A failed lookup is an empty set here, as `Builder.running_containers/0`
  # has always answered: the scratch age floor makes that safe. Only the hex
  # sweep fails closed.
  defp scratch_containers(opts) do
    case Keyword.get_lazy(opts, :running_containers, &Builder.running_containers/0) do
      fun when is_function(fun, 0) -> scratch_set(fun.())
      other -> scratch_set(other)
    end
  end

  defp scratch_set(%MapSet{} = names), do: names
  defp scratch_set({:ok, %MapSet{} = names}), do: names
  defp scratch_set(_), do: MapSet.new()

  defp scratch_dead?(name, now, max_age, live, containers) do
    cond do
      # `Builder.container_name/1` is "ncc-" <> safe_name(run_id). A running
      # container means a build is still writing in there, whatever its age says.
      MapSet.member?(containers, "ncc-#{name}") ->
        false

      # `Ingest` args carry `run_id`, so this match is exact, not heuristic.
      MapSet.member?(live, name) ->
        false

      true ->
        stale?(name, now, max_age)
    end
  end

  defp stale?(name, now, max_age) do
    case started_at_ms(name) do
      {:ok, ts} ->
        now - ts > max_age

      :unparseable ->
        # A name that does not parse was not minted by `Build.run_id/2`, so
        # nothing here knows what it is or who owns it. That wants a human, not
        # an `rm_rf`.
        Logger.warning("Sweep skipping unrecognized scratch dir: #{name}")
        false
    end
  end

  # `Build.run_id/2` mints "#{package}-#{version}-#{ts}" and `Builder.safe_name/1`
  # only rewrites characters outside [A-Za-z0-9_.-], so the trailing digits
  # survive intact.
  #
  # Deliberately not `File.stat` mtime: a directory's mtime moves only when a
  # direct child is added or removed, so a build writing deep inside `work/` for
  # an hour still looks untouched. Ageing by mtime would delete live builds.
  defp started_at_ms(name) do
    case Regex.run(~r/-(\d+)$/, name) do
      [_, ts] -> {:ok, String.to_integer(ts)}
      nil -> :unparseable
    end
  end

  defp live_run_ids(opts) do
    case Keyword.fetch(opts, :live_run_ids) do
      {:ok, set} -> {:ok, set}
      :error -> query_live_run_ids()
    end
  end

  defp query_live_run_ids do
    ids =
      from(j in "oban_jobs",
        # Oban stores the worker name without the "Elixir." prefix.
        where: j.worker == "Portal.Workers.Ingest",
        where: j.state in ^@live_states,
        select: fragment("?->>'run_id'", j.args)
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)
      # Compare the sanitized form: a semver with build metadata ("1.0.0+build.1")
      # lands on disk as "1.0.0_build.1" and would otherwise never match its own
      # ingest job — deleting a tree the ingest is about to read.
      |> MapSet.new(&Builder.safe_name/1)

    {:ok, ids}
  rescue
    exception ->
      # Without the live set every scratch dir looks orphaned. Failing closed is
      # the only safe answer to a database problem.
      Logger.error("Sweep could not load live ingest jobs: #{Exception.message(exception)}")
      :error
  end

  # ── Build cache ────────────────────────────────────────────────────────────

  defp sweep_build_cache(opts) do
    root = Keyword.get_lazy(opts, :build_cache, &Builder.build_cache/0)

    with root when is_binary(root) <- root,
         :ok <- refuse_overlap(root, opts),
         {:ok, names} <- list_dir(root),
         {:ok, keep} <- cache_keep_set(opts) do
      now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
      {kept, dead} = Enum.split_with(names, &MapSet.member?(keep, &1))

      dead
      |> Enum.reject(&within_grace?(Path.join(root, &1), now))
      |> Enum.map(&Path.join(root, &1))
      |> delete_all(opts, "build-cache")
      |> add(sweep_staging(root, kept, opts))
    else
      _ -> empty()
    end
  end

  # `NccWorker.BuildCache.store_entry/2` stages into "<slug>/<key>.tmp.<hex>" and
  # renames. It cleans up after itself on a returned error, but a SIGKILL between
  # the `cp -a` and the rename leaves a full copied dep tree inside a *live* slug
  # — which the keep set above protects, forever.
  #
  # These are unambiguous garbage: the rename is atomic, so no reader can ever
  # find an entry under a `.tmp.` name.
  defp sweep_staging(root, slugs, opts) do
    slugs
    |> Enum.flat_map(fn slug ->
      dir = Path.join(root, slug)

      case list_dir(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&Regex.match?(@staging_pattern, &1))
          |> Enum.map(&Path.join(dir, &1))

        _ ->
          []
      end
    end)
    |> delete_all(opts, "build-cache staging")
  end

  defp cache_keep_set(opts) do
    digest = Keyword.get_lazy(opts, :current_digest, &current_image_digest/0)

    if digest in [nil, "", zero_digest()] do
      # `Builder.image_digest/1` answers with the zero digest on any failure, so
      # a docker hiccup is indistinguishable from "the live image is gone". We
      # cannot tell which slug is live, and guessing wrong costs a ~5.7G rebuild.
      Logger.warning("Sweep skipping build-cache prune: current image digest unresolved")
      :error
    else
      # A build enqueued against the previous image is still legitimate and will
      # look for its own slug when it runs.
      {:ok, MapSet.new([Builder.cache_slug(digest) | pending_build_slugs()])}
    end
  end

  defp pending_build_slugs do
    from(j in "oban_jobs",
      where: j.worker == "Portal.Workers.Build",
      where: j.state in ^@live_states,
      select: fragment("?->>'image_digest'", j.args)
    )
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Builder.cache_slug/1)
  rescue
    # Keep nothing extra rather than abort: the current digest is already in the
    # keep set, so the worst case is evicting a slug a queued build wanted, which
    # costs one cache miss.
    exception ->
      Logger.warning("Sweep could not load pending builds: #{Exception.message(exception)}")
      []
  end

  defp within_grace?(path, now) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> now - mtime * 1000 < @cache_grace_ms
      # Unreadable means unknown, and unknown means leave it alone.
      {:error, _reason} -> true
    end
  end

  defp current_image_digest, do: Builder.docker_image() |> Builder.image_digest()

  defp zero_digest, do: "sha256:" <> String.duplicate("0", 64)

  # A misconfigured `build_cache` pointing at a shared cache root would let this
  # delete data no one can cheaply rebuild. Cheap to check, expensive to skip.
  defp refuse_overlap(root, opts) do
    expanded = Path.expand(root)

    protected =
      [
        Keyword.get_lazy(opts, :nerves_cache, &Builder.nerves_cache/0),
        Keyword.get_lazy(opts, :hex_cache, &Builder.hex_cache/0),
        Keyword.get_lazy(opts, :scratch_root, &Builder.scratch_root/0)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.expand/1)

    if Enum.any?(protected, &(&1 == expanded or String.starts_with?(expanded, &1 <> "/"))) do
      Logger.error("Sweep refusing build-cache prune: #{root} overlaps a protected cache")
      :error
    else
      :ok
    end
  end

  # ── Hex cache ──────────────────────────────────────────────────────────────

  @default_hex_cache_max_bytes 20 * 1024 * 1024 * 1024

  # Never evict a file used this recently, even if that leaves the cache over
  # its bound. A build that just got a 304 for a tarball reads it from here a
  # moment later; deleting it in between fails that build. Two hours is the
  # docker wall clock (`Portal.Builder.total_timeout_ms/0`), so anything older
  # belongs to a build that is already over.
  @hex_in_use_ms :timer.hours(2)

  # How far past `now` a timestamp may be and still count as "just used".
  @future_tolerance_ms :timer.minutes(5)

  # The only regular files at the cache root that Hex itself owns. Anything
  # else there is either a `.cache.ets.<n>` temp left by a failed
  # `HexHome.publish` or something a build wrote to dodge the bound.
  @hex_root_keep ["cache.ets", "hex.config"]

  # Everything under `packages/` counts toward the bound, whatever its name, so
  # a build cannot dodge it with `packages/hexpm/x.bin`. At the root only
  # `cache.ets` (the signed registry) and `hex.config` are kept for good; other
  # regular files there go once they are older than the scratch max age.
  defp sweep_hex_cache(opts) do
    root = Keyword.get_lazy(opts, :hex_cache, &Builder.hex_cache/0)

    # This guard, not the lstat checks below, is what makes the hex sweep safe.
    # Erlang has no `openat`/`O_NOFOLLOW`/`unlinkat`, so every lstat-then-act
    # here has a gap a concurrent writer can race: flip a `packages/`
    # subdirectory to a symlink between the check and the `File.ls`/`File.rm`,
    # and Sweep walks or unlinks on the host. Nothing but a build container
    # writes `/hex-cache`, so with no build running there is no one to race.
    # The lstat checks and `still_inside?/2` stay as defence in depth.
    with root when is_binary(root) <- root,
         :ok <- no_builds_running(opts),
         :ok <- real_dir(root),
         {:ok, packages?} <- packages_dir(Path.join(root, "packages")) do
      root_files = hex_root_files(root)
      package_files = if packages?, do: walk(Path.join(root, "packages")), else: []

      # Sampled after the walk, not before: a file written during the walk must
      # compare as just-used, not as "in the future".
      now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
      junk = hex_root_junk(root_files, now, opts)
      evict = hex_evictions(package_files, now, opts)

      # A build can start after the first check. Ask again right before the
      # first unlink; the guarantee is "no build was running when the walk
      # started and when deletion started", and not more than that.
      case no_builds_running(opts) do
        :ok ->
          junk
          |> delete_sized(root, opts, "hex cache junk")
          |> add(delete_sized(evict, root, opts, "hex cache file"))

        :error ->
          empty()
      end
    else
      _ -> empty()
    end
  end

  # Build containers are `"ncc-" <> safe_name(run_id)` (`Builder.container_name/1`).
  defp no_builds_running(opts) do
    case container_lookup(opts) do
      {:ok, names} ->
        case Enum.count(names, &String.starts_with?(&1, "ncc-")) do
          0 ->
            :ok

          n ->
            Logger.info("Sweep skipping hex cache: #{n} build container(s) running")
            :error
        end

      :error ->
        # Unknown means a build may be running, and then the race is open.
        Logger.warning("Sweep skipping hex cache: could not list running containers")
        :error
    end
  end

  # `:running_containers` is a `MapSet`, `:error` for a failed lookup, or a
  # zero-arity function returning either (so a test can change the answer
  # between the two checks). The default asks docker, and unlike
  # `Builder.running_containers/0` tells a failure apart from "none running".
  defp container_lookup(opts) do
    case Keyword.get_lazy(opts, :running_containers, &Builder.fetch_running_containers/0) do
      fun when is_function(fun, 0) -> normalize_lookup(fun.())
      other -> normalize_lookup(other)
    end
  end

  defp normalize_lookup(%MapSet{} = names), do: {:ok, names}
  defp normalize_lookup({:ok, %MapSet{}} = ok), do: ok
  defp normalize_lookup(_), do: :error

  # A missing `packages/` is a fresh cache: the root can still be tidied. Any
  # other non-directory there is a build tampering with the cache, and then
  # nothing is swept at all.
  defp packages_dir(packages) do
    case File.lstat(packages) do
      {:error, :enoent} ->
        {:ok, false}

      _ ->
        with :ok <- real_dir(packages), do: {:ok, true}
    end
  end

  defp hex_root_files(root) do
    case list_dir(root) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 in @hex_root_keep))
        |> Enum.flat_map(&regular_file(Path.join(root, &1)))

      :error ->
        []
    end
  end

  defp hex_root_junk(files, now, opts) do
    max_age = Keyword.get(opts, :max_age_ms, configured_max_age_ms())
    Enum.filter(files, &(now - last_used_ms(&1, now) > max_age))
  end

  defp hex_evictions(files, now, opts) do
    max = Keyword.get_lazy(opts, :hex_cache_max_bytes, &configured_hex_cache_max_bytes/0)
    total = files |> Enum.map(& &1.size) |> Enum.sum()

    if total <= max do
      []
    else
      files
      |> Enum.map(&Map.put(&1, :used_ms, last_used_ms(&1, now)))
      |> Enum.reject(&(now - &1.used_ms < @hex_in_use_ms))
      |> Enum.sort_by(& &1.used_ms)
      |> evict_until(total - max)
    end
  end

  # `File.dir?/1` and `File.ls/1` both follow a symlink, so they cannot be the
  # gate: a build can `rm -rf /hex-cache/packages && ln -s / /hex-cache/packages`
  # (or swap the whole cache root the same way, if it ever owns the parent), and
  # the walk below would then evict the oldest files on the host. Only a real
  # directory, as `File.lstat/2` sees it, is ever swept.
  defp real_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        :error

      other ->
        Logger.warning(
          "Sweep skipping hex cache: #{path} is not a real directory (#{inspect(lstat_type(other))})"
        )

        :error
    end
  end

  defp lstat_type({:ok, %File.Stat{type: type}}), do: type
  defp lstat_type({:error, reason}), do: reason

  # Every regular file under packages/, with its size and last use, found by
  # hand-walking the tree rather than `Path.wildcard/1` + `File.stat/2`.
  #
  # `/hex-cache` is bind-mounted read-write into every build container, which
  # runs the package's own build scripts, so everything under `packages/` is
  # attacker-controlled. A build could plant `packages/hexpm/x -> /` (or any
  # other symlink) before Sweep next runs on the host. `Path.wildcard/1`'s
  # `**` descends through a symlinked directory, and `File.stat/2` follows a
  # symlink to read the target's metadata — together they would make Sweep
  # walk, and then delete, the oldest files anywhere the ncc user can reach,
  # not just inside the cache. `File.lstat/2` reports the link itself and
  # never the target, so only a real `:directory` is descended into and only
  # a real `:regular` file is ever collected; a `:symlink` (file or
  # directory) is skipped outright — never followed, never deleted.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &walk_entry(Path.join(dir, &1)))
      {:error, _reason} -> []
    end
  end

  defp walk_entry(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> walk(path)
      {:ok, %File.Stat{type: :regular} = stat} -> [cached_file(path, stat)]
      _ -> []
    end
  end

  defp regular_file(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> [cached_file(path, stat)]
      _ -> []
    end
  end

  defp cached_file(path, stat),
    do: %{path: path, size: stat.size, atime: stat.atime, mtime: stat.mtime}

  # Least-recently-used, approximately. Hex does not rewrite a cached tarball
  # on a cache hit (it gets a 304), so mtime alone is first-download order and
  # would evict the most-used tarballs first. atime is what a hit moves:
  # `relatime` updates it at most once a day, which is fine resolution for an
  # hourly sweep.
  #
  # A time a little past `now` is clock skew or a write that landed while the
  # walk ran: it counts as just used. One further out than
  # `@future_tolerance_ms` was set by hand, since nothing legitimate writes
  # one, and counts as the epoch — evicted first — rather than letting a
  # hostile file outrank every real tarball.
  defp last_used_ms(%{atime: atime, mtime: mtime}, now) do
    ms = max(atime, mtime) * 1000
    if ms > now + @future_tolerance_ms, do: 0, else: ms
  end

  # Oldest first, stop as soon as enough is gone. Returns the files, not just
  # paths, so the deletion log can use the sizes already in hand.
  defp evict_until(files, bytes_to_free) do
    files
    |> Enum.reduce_while({[], 0}, fn file, {acc, freed} ->
      if freed >= bytes_to_free,
        do: {:halt, {acc, freed}},
        else: {:cont, {[file | acc], freed + file.size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # `delete_all/3` runs `du` per path to learn a size it does not have. Here
  # the sizes come from the stat that chose the files, so a bulk eviction of
  # thousands of tarballs does not fork thousands of `du`s.
  #
  # The walk that chose these files ran a while ago, and a build may have
  # swapped a directory on the path for a symlink since. Re-checking the whole
  # chain immediately before each unlink narrows that window to the gap
  # between two syscalls; `File.rm/1` then unlinks the one name it is given
  # and never recurses.
  defp delete_sized(files, root, opts, label) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    Enum.reduce(files, empty(), fn %{path: path, size: bytes}, acc ->
      case remove_cached_file(root, path, dry_run?) do
        :ok ->
          Logger.info("Sweep removed #{label} #{Path.basename(path)} (#{mb(bytes)} MB)")
          %{count: acc.count + 1, bytes: acc.bytes + bytes}

        {:error, reason} ->
          Logger.warning("Sweep could not remove #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp remove_cached_file(root, path, dry_run?) do
    cond do
      not still_inside?(root, path) -> {:error, :path_changed_under_sweep}
      dry_run? -> :ok
      true -> rm_file(path)
    end
  end

  # Every directory from `root` down to the file's parent is still a real
  # directory, and the file itself is still a regular file.
  defp still_inside?(root, path) do
    rel = Path.relative_to(path, root)

    if rel == path or rel in [".", ""] or ".." in Path.split(rel) do
      false
    else
      parents =
        rel
        |> Path.split()
        |> Enum.drop(-1)
        |> Enum.scan(root, &Path.join(&2, &1))

      Enum.all?([root | parents], &(lstat_type(File.lstat(&1)) == :directory)) and
        lstat_type(File.lstat(path)) == :regular
    end
  end

  # Paths come from an lstat walk of the configured hex cache, re-checked by
  # `still_inside?/2` just before this call. `File.rm/1` unlinks one name.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm_file(path), do: File.rm(path)

  defp configured_hex_cache_max_bytes do
    :portal
    |> Application.get_env(Portal.Builder, [])
    |> Keyword.get(:hex_cache_max_bytes, @default_hex_cache_max_bytes)
  end

  # ── Deletion ───────────────────────────────────────────────────────────────

  defp delete_all(paths, opts, label) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    Enum.reduce(paths, empty(), fn path, acc ->
      bytes = du(path)

      # Each deletion stands alone: one EACCES must not stop the sweep from
      # reclaiming everything else, which is the entire point of running it.
      case maybe_remove(path, dry_run?) do
        :ok ->
          Logger.info("Sweep removed #{label} #{Path.basename(path)} (#{mb(bytes)} MB)")
          %{count: acc.count + 1, bytes: acc.bytes + bytes}

        {:error, reason} ->
          Logger.warning("Sweep could not remove #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  # Paths come from listing configured scratch/cache roots after liveness and retention checks.
  # File.rm_rf removes a symlink itself; it does not recurse into the symlink target.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # `du -sk` rather than walking the tree in Elixir: these are multi-gigabyte
  # trees of tens of thousands of files and the number only feeds a log line.
  defp du(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {kb, _rest} -> kb * 1024
          :error -> 0
        end

      {_out, _status} ->
        0
    end
  rescue
    _ -> 0
  end

  # A missing root is not a failure: it is what every host that does not run
  # builds looks like, and what the build host looks like before its first build.
  defp list_dir(path) do
    case File.ls(path) do
      {:ok, names} ->
        {:ok, names}

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("Sweep could not list #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp configured_max_age_ms do
    :portal
    |> Application.get_env(Portal.Builder, [])
    |> Keyword.get(:scratch_max_age_ms, @default_max_age_ms)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp add(a, b), do: %{count: a.count + b.count, bytes: a.bytes + b.bytes}

  defp empty, do: %{count: 0, bytes: 0}

  defp mb(bytes), do: Float.round(bytes / 1024 / 1024, 1)
  defp maybe_remove(_path, true), do: :ok
  defp maybe_remove(path, false), do: rm(path)
end
