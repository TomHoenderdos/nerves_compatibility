defmodule Portal.Catalog.ModuleIndex do
  @moduledoc """
  Which popular Hex packages define a module (otp-probe round 3, R2-1), and
  the ingest refusal it backs.

  The worker's judge passes a package's compile-time probe of a module that
  only a declared, optional and absent dependency defines
  (`NccWorker.Portability.Declared`): a user with that dependency has
  another closure, so the client never serves them the build. It cannot
  tell whether another package, which nothing in the build declares,
  defines the same module: a user with that one has the build's closure and
  finds the module, and their compile differs (bitcrowd_ecto's `Money`,
  declared from ex_money, also defined by money). So the judge records each
  such probe (`compile_observations.declared_absent`: the module, the
  declared packages that define it and their applications, how it was
  asked), and ingest refuses the build when this index shows another
  package with at least `min_recent/0` recent downloads defining the module,
  unless the lock or the record names that package or its application
  (`refusal/2`).

  The index lives here, not in the worker, because:

    * it needs Hex-wide data the worker does not have: every popular
      package's modules, and the download counts `catalog_packages` keeps
      (refreshed weekly by `Portal.Workers.HexMetaRefresh`);
    * ingest is the one place every build passes through, local and remote
      alike, so the decision is the same whichever builder ran the build,
      and needs no builder protocol change;
    * the recorded probes stay on the row, so the index re-checks served
      rows after each complete run (`recheck/1`), and client 0.9 can check
      them itself.

  **Complete or nothing (round 5, R3-1).** A run (`refresh/1`) is a
  generation of its own. It reads the last release, as the Hex registry
  lists it (round 6, R5-1), and the latest stable one when the last is a
  prerelease (final round, R6-1: Mix resolves the stable one by default),
  of every candidate
  (`hex_downloads_recent >= min_recent/0`), its tarball checked against the
  registry's outer checksum, and takes the union of the modules its sources
  define (`Compatibility.HexModules`: literal definitions, leex and yecc
  files) and of the module names in our own passing builds' manifests of the
  package (R3-5b: modules a macro defines). A package already indexed at
  that release is confirmed without a fetch. The index is usable only when
  it holds every current candidate at its latest release (`complete?/0`,
  judged when it is used, round 6, R5-4). Until then (no run yet, a
  candidate that crossed the threshold since the last run, a release not
  fetched yet, a failed fetch or checksum, a tarball over the caps), every
  recorded declared-absent probe refuses. A newer run supersedes an older
  one, which stops at its next package.

  After a complete run the index re-checks every served row that carries a
  record and withholds (revokes, with a tag and an undo) any that now
  collides (`recheck/1`, R3-5a).
  """

  alias Portal.Repo

  require Logger

  @min_recent 1_000
  @max_concurrency 4
  @package_timeout_ms 120_000
  # The index's own tarball cap: a few popular packages ship more than the
  # 8 MiB a build's tarball check allows (rocksdb, astro), and a package the
  # index cannot read keeps it incomplete.
  @max_tarball_bytes 16 * 1024 * 1024
  # A tarball over this size (compressed) is parsed while no other one over
  # it is (`read_release/3`).
  @big_parse_bytes 1024 * 1024

  @doc "The recent-download count from which another package defining a probed module refuses."
  @spec min_recent() :: pos_integer()
  def min_recent, do: @min_recent

  @doc "The most packages `refresh/1` fetches and parses at once."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: @max_concurrency

  @doc """
  Whether the index holds, now, a successful entry for every current
  candidate (`hex_downloads_recent >= min_recent/0` in the catalog as it is
  now) at the releases the Hex registry listed at the last run's start: its
  last version and, when that is a prerelease, its latest stable one too
  (round 6, R5-4; final round, R6-1): the only state in which `refusal/2`
  decides by the index.
  A candidate the last run did not see (one that crossed the threshold
  since), a release it did not index (a failed fetch, a run still going or
  stopped before it) or no run at all makes it incomplete. A candidate the
  registry did not list has no release to index and does not count.
  """
  @spec complete?() :: boolean()
  def complete? do
    %{rows: [[complete]]} =
      Repo.query!(
        """
        SELECT EXISTS (SELECT 1 FROM catalog_module_index_runs)
           AND NOT EXISTS (
             SELECT 1 FROM catalog_packages p
             LEFT JOIN catalog_module_index_candidates c ON c.package = p.name
             LEFT JOIN catalog_module_index_packages i ON i.package = p.name
             WHERE coalesce(p.hex_downloads_recent, 0) >= $1
               AND (c.package IS NULL
                    OR (c.version IS NOT NULL
                        AND (i.version IS DISTINCT FROM c.version
                             OR i.stable IS DISTINCT FROM c.stable))))
        """,
        [@min_recent]
      )

    complete
  end

  @doc "The latest run's row, and how many runs there have been."
  @spec status() :: map()
  def status do
    %{rows: [[runs]]} = Repo.query!("SELECT count(*) FROM catalog_module_index_runs", [])
    Map.merge(latest_run() || %{}, %{runs: runs})
  end

  @run_fields [
    :generation,
    :started_at,
    :finished_at,
    :candidates,
    :indexed,
    :unchanged,
    :failed,
    :complete,
    :withheld
  ]

  defp latest_run do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT generation, started_at, finished_at, candidates, indexed, unchanged, failed,
               complete, withheld
        FROM catalog_module_index_runs ORDER BY generation DESC LIMIT 1
        """,
        []
      )

    case rows do
      [row] -> @run_fields |> Enum.zip(row) |> Map.new()
      [] -> nil
    end
  end

  @doc "The indexed packages that define `module`, sorted."
  @spec definers(String.t()) :: [String.t()]
  def definers(module) when is_binary(module) do
    %{rows: rows} =
      Repo.query!(
        "SELECT package FROM catalog_module_definers WHERE module = $1 ORDER BY package",
        [module]
      )

    List.flatten(rows)
  end

  @doc """
  The refusal of a build whose judge recorded `items` (its
  `compile_observations.declared_absent`) and whose lock names `locked`
  (its keys: application names), or `nil`. A module item refuses when an
  indexed package with at least `min_recent/0` recent downloads defines the
  module and neither the item's `declared` packages, its `declared_apps`,
  `locked` nor the `definers` of a module `probe` compile input of the same
  module (`inputs`, S10) name the package or its application; any item
  while the index is not complete; a `truncated` item always. Each module
  `probe` input is checked the same way against its own `definers`, so a
  served one recorded before the index showed a definer collides
  (`recheck/1`).
  """
  @spec refusal([map()] | nil, [String.t()], [map()] | nil) :: String.t() | nil
  def refusal(items, locked, inputs \\ nil) do
    probes = module_probes(inputs)
    records = if(is_list(items), do: items, else: []) ++ Enum.map(probes, &probe_record/1)

    if records == [] do
      nil
    else
      complete = complete?()
      covered = Map.new(probes, &{&1["name"], &1["definers"]})
      Enum.find_value(records, &item_refusal(&1, MapSet.new(locked), complete, covered))
    end
  end

  @doc """
  S10: `inputs` (a build's `compile_inputs`) with each module `probe` item's
  `definers` grown by every indexed package with at least `min_recent/0`
  recent downloads that defines the module, and that package's
  application, sorted and each once: what client 0.9 checks its project
  for. `{:refuse, reason}` when there is such an item and the index is not
  complete, as a declared-absent record refuses then. Anything that is not
  a list, or holds no module probe, comes back as it is.
  """
  @spec settle_inputs(term()) :: {:ok, term()} | {:refuse, String.t()}
  def settle_inputs(inputs) do
    case module_probes(inputs) do
      [] ->
        {:ok, inputs}

      [first | _] ->
        if complete?(),
          do: {:ok, Enum.map(inputs, &settle_input/1)},
          else: {:refuse, reason(first["name"], "a probe", "module index not complete")}
    end
  end

  defp settle_input(%{"kind" => "probe", "of" => "module", "name" => module} = item)
       when is_binary(module) do
    found =
      for {package, app} <- popular_definers(module), n <- [package, app], is_binary(n), do: n

    %{item | "definers" => (List.wrap(item["definers"]) ++ found) |> Enum.uniq() |> Enum.sort()}
  end

  defp settle_input(item), do: item

  defp module_probes(inputs) when is_list(inputs) do
    for %{"kind" => "probe", "of" => "module", "name" => name} = item <- inputs,
        is_binary(name),
        do: Map.put(item, "definers", List.wrap(item["definers"]))
  end

  defp module_probes(_inputs), do: []

  # A module probe input, checked as a declared-absent record whose definers
  # are named: a popular definer it does not name collides (it was recorded
  # before the index showed that package).
  defp probe_record(item),
    do: %{
      "kind" => "module_absent",
      "module" => item["name"],
      "declared" => item["definers"],
      "declared_apps" => []
    }

  defp item_refusal(%{"kind" => "truncated"}, _locked, _complete, _covered),
    do: Compatibility.Portability.dependency_probe() <> "too many declared-absent probes recorded"

  defp item_refusal(
         %{"kind" => "module_absent", "module" => module} = item,
         locked,
         complete,
         covered
       )
       when is_binary(module) do
    via = if is_binary(item["via"]), do: item["via"], else: "a probe"

    named =
      [item["declared"], item["declared_apps"], Map.get(covered, module)]
      |> Enum.flat_map(&List.wrap/1)
      |> MapSet.new()
      |> MapSet.union(locked)

    others =
      if complete,
        do:
          for(
            {package, app} <- popular_definers(module),
            not MapSet.member?(named, package),
            not (is_binary(app) and MapSet.member?(named, app)),
            do: package
          ),
        else: :not_complete

    case others do
      :not_complete -> reason(module, via, "module index not complete")
      [] -> nil
      others -> reason(module, via, "also defined by " <> Enum.join(others, ", "))
    end
  end

  defp item_refusal(_item, _locked, _complete, _covered),
    do: Compatibility.Portability.dependency_probe() <> "unreadable declared-absent probe record"

  defp reason(module, via, why),
    do: Compatibility.Portability.dependency_probe() <> "#{module} via #{via} (#{why})"

  defp popular_definers(module) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.package, i.app FROM catalog_module_definers d
        JOIN catalog_packages p ON p.name = d.package
        LEFT JOIN catalog_module_index_packages i ON i.package = d.package
        WHERE d.module = $1 AND coalesce(p.hex_downloads_recent, 0) >= $2
        ORDER BY d.package
        """,
        [module, @min_recent]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @doc """
  A run: reads the latest release of every candidate the index does not
  hold at it, confirms the rest, and marks its generation complete when
  every candidate is confirmed in it. A complete run then re-checks the
  served rows (`recheck/1`, unless `recheck: false`).

  Safe to start by hand on a host short on memory (round 4):

    * `dry_run: true` reads only the registry and writes nothing: it
      returns `%{to_fetch, releases_to_fetch, unchanged, below_threshold,
      not_in_registry}`;
    * at most `max_concurrency/0` (4) packages are fetched and parsed at
      once (`:concurrency` may lower it, never raise it), each with its
      tarball in memory only while it is read (at most 16 MiB), and killed
      after 2 minutes; a tarball over 1 MiB compressed is parsed while no
      other one over it is, so a run stays well under 1 GB (aws parses at
      about 230 MB);
    * each package is stored in a transaction of its own as soon as it is
      read, most downloaded first, so a run that is stopped keeps what it
      stored and the next run fetches only the rest (and confirms the rest
      without a fetch).

  Each candidate's latest release is the Hex registry's
  (`Portal.HexRegistry.snapshot/1`, read once at the run's start), never
  `catalog_packages.hex_latest_version`; a registry that cannot be read is a
  failed run that changes nothing. The dry run reads the registry too.

  Options: `:registry` (`fn -> {:ok, %{name => {last, stable}}} | {:error,
  why} end`), `:tarball` and `:outer_checksum` (`fn name, version -> {:ok,
  value} | {:error, why} end`, default `Portal.HexDeps`), `:read` (default
  `Compatibility.HexModules.read/2`), `:big_parse_bytes`, `:limit`,
  `:concurrency`, `:dry_run`, `:recheck`.
  """
  @spec refresh(keyword()) :: %{atom() => term()}
  def refresh(opts \\ []) do
    registry = Keyword.get(opts, :registry, &registry/0)

    case registry.() do
      {:ok, latest} ->
        rows = candidates(Keyword.get(opts, :limit, 100_000), latest)
        {listed, unlisted} = Enum.split_with(rows, &listed?/1)
        {todo, unchanged} = Enum.split_with(listed, &(not indexed?(&1)))

        if Keyword.get(opts, :dry_run, false) do
          %{
            to_fetch: length(todo),
            releases_to_fetch: todo |> Enum.map(&length(releases(&1))) |> Enum.sum(),
            unchanged: length(unchanged),
            below_threshold: below_threshold(),
            not_in_registry: length(unlisted)
          }
        else
          {:ok, generation} = start_run(length(listed))
          :ok = store_candidates(rows, generation)
          result = run(generation, listed, opts)
          finish(generation, listed, result, opts)
        end

      {:error, why} ->
        Logger.warning(
          "module index: the Hex registry could not be read: #{inspect(why, limit: 5)}"
        )

        %{complete: false, error: why}
    end
  end

  # Every package the registry lists, by name, with its last version and
  # its latest stable one (final round, R6-1: when the last version is a
  # prerelease, Mix resolves the stable one by default, and both are read),
  # `nil` when it has no stable release (`Portal.HexRegistry`: `/names`
  # joined with `/versions`, signed by hex.pm).
  defp registry do
    case Portal.HexRegistry.snapshot(all_versions: true) do
      {:ok, entries} ->
        {:ok, Map.new(entries, &{&1.name, {&1.latest_version, latest_stable(&1.versions)}})}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # The newest version that is no prerelease, of a list in registry order.
  @spec latest_stable([String.t()]) :: String.t() | nil
  def latest_stable(versions) when is_list(versions) do
    versions
    |> Enum.filter(&match?({:ok, %Version{pre: []}}, Version.parse(&1)))
    |> Enum.max_by(&Version.parse!/1, Version, fn -> nil end)
  end

  def latest_stable(_versions), do: nil

  # A candidate row: `[name, last, stable, indexed last, indexed stable]`.
  defp listed?([_name, last, _stable, _il, _is]), do: last != nil
  defp indexed?([_name, last, stable, il, is]), do: last == il and stable == is

  # The releases to read for a candidate: its last version and, when it
  # differs, its latest stable one.
  defp releases([_name, last, stable, _il, _is]),
    do: Enum.uniq(Enum.reject([last, stable], &is_nil/1))

  # Every candidate with the registry's versions at this run's start (NULL
  # last: the registry does not list it), for `complete?/0`.
  defp store_candidates(rows, generation) do
    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        "catalog_module_index_candidates",
        Enum.map(chunk, fn [name, last, stable, _, _] ->
          %{package: name, version: last, stable: stable, generation: generation}
        end),
        on_conflict: {:replace, [:version, :stable, :generation]},
        conflict_target: [:package]
      )
    end)
  end

  @doc "Starts a run of `candidates` packages: its generation, which makes the index incomplete until it finishes complete."
  @spec start_run(non_neg_integer()) :: {:ok, pos_integer()}
  def start_run(candidates) do
    %{rows: [[generation]]} =
      Repo.query!(
        "INSERT INTO catalog_module_index_runs (started_at, candidates) VALUES (now(), $1) RETURNING generation",
        [candidates]
      )

    {:ok, generation}
  end

  defp run(generation, rows, opts) do
    # Not cached: a run reads each package's registry entry once, and the
    # 5,008 decoded entries would hold about 90 MB in `Portal.HexDeps`'s
    # table for an hour.
    tarball =
      Keyword.get(
        opts,
        :tarball,
        &Portal.HexDeps.tarball(&1, &2, max_bytes: @max_tarball_bytes, cache: false)
      )

    checksum =
      Keyword.get(opts, :outer_checksum, &Portal.HexDeps.outer_checksum(&1, &2, cache: false))

    concurrency =
      opts |> Keyword.get(:concurrency, @max_concurrency) |> min(@max_concurrency) |> max(1)

    reader = %{
      tarball: tarball,
      checksum: checksum,
      read: Keyword.get(opts, :read, &Compatibility.HexModules.read/2),
      big: Keyword.get(opts, :big_parse_bytes, @big_parse_bytes)
    }

    rows
    |> Task.async_stream(
      fn [name, last, stable, _il, _is] = row ->
        cond do
          superseded?(generation) -> :superseded
          indexed?(row) -> confirm(name, last, stable, generation)
          true -> index_release(name, {last, stable}, releases(row), generation, reader)
        end
      end,
      max_concurrency: concurrency,
      timeout: @package_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{indexed: 0, unchanged: 0, failed: 0, superseded: 0}, fn
      {:ok, :indexed}, acc -> Map.update!(acc, :indexed, &(&1 + 1))
      {:ok, :unchanged}, acc -> Map.update!(acc, :unchanged, &(&1 + 1))
      {:ok, :superseded}, acc -> Map.update!(acc, :superseded, &(&1 + 1))
      _other, acc -> Map.update!(acc, :failed, &(&1 + 1))
    end)
  end

  # Complete when every candidate of the run's start is confirmed in this
  # generation at the version the run read, and no newer run started.
  defp finish(generation, rows, result, opts) do
    names = Enum.map(rows, &hd/1)

    %{rows: [[confirmed]]} =
      Repo.query!(
        """
        SELECT count(*) FROM catalog_module_index_packages i
        JOIN catalog_module_index_candidates c ON c.package = i.package
        WHERE i.package = ANY($1) AND i.generation = $2 AND i.version = c.version
          AND i.stable IS NOT DISTINCT FROM c.stable
        """,
        [names, generation]
      )

    complete =
      result.failed == 0 and result.superseded == 0 and confirmed == length(rows) and
        not superseded?(generation)

    Repo.query!(
      """
      UPDATE catalog_module_index_runs
      SET finished_at = now(), indexed = $2, unchanged = $3, failed = $4, complete = $5
      WHERE generation = $1
      """,
      [generation, result.indexed, result.unchanged, result.failed + result.superseded, complete]
    )

    withheld =
      if complete and Keyword.get(opts, :recheck, true),
        do: recheck(generation: generation).withheld,
        else: nil

    requeued = if complete, do: requeue_not_complete(), else: 0

    Map.merge(result, %{
      generation: generation,
      complete: complete,
      withheld: withheld,
      requeued: requeued
    })
  end

  defp superseded?(generation) do
    %{rows: [[latest]]} =
      Repo.query!("SELECT max(generation) FROM catalog_module_index_runs", [])

    latest != generation
  end

  # Every package with at least `min_recent/0` recent downloads, most
  # downloaded first, as `[name, registry latest version or nil, indexed
  # version or nil]`. Never `hex_latest_version`, a nomination column
  # (round 6, R5-1).
  defp candidates(limit, latest) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.name, i.version, i.stable
        FROM catalog_packages p
        LEFT JOIN catalog_module_index_packages i ON i.package = p.name
        WHERE coalesce(p.hex_downloads_recent, 0) >= $1
        ORDER BY p.hex_downloads_recent DESC, p.name
        LIMIT $2
        """,
        [@min_recent, limit]
      )

    for [name, il, is] <- rows do
      {last, stable} = Map.get(latest, name, {nil, nil})
      [name, last, stable, il, is]
    end
  end

  defp below_threshold do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM catalog_packages WHERE coalesce(hex_downloads_recent, 0) < $1",
        [@min_recent]
      )

    n
  end

  # Indexed already at this release: confirmed in this generation, with the
  # module names of builds made since added.
  defp confirm(name, version, stable, generation) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        insert_definers(name, manifest_modules(name))

        Repo.query!(
          """
          UPDATE catalog_module_index_packages SET generation = $3
          WHERE package = $1 AND version = $2 AND stable IS NOT DISTINCT FROM $4
          """,
          [name, version, generation, stable]
        )

        :ok
      end)

    :unchanged
  end

  # Every release of `releases` read and checked, one after another, the
  # union of their modules stored under `{last, stable}`; any release that
  # cannot be read leaves the package as it was (`:failed`).
  defp index_release(name, {last, stable}, releases, generation, reader) do
    read =
      Enum.reduce_while(releases, {:ok, [], nil}, fn version, {:ok, acc, app} ->
        case read_release(name, version, reader) do
          {:ok, %{modules: modules, app: found}} -> {:cont, {:ok, modules ++ acc, app || found}}
          why -> {:halt, {version, why}}
        end
      end)

    case read do
      {:ok, modules, app} ->
        store(name, {last, stable}, generation, app, Enum.uniq(modules ++ manifest_modules(name)))

      {version, why} ->
        Logger.warning("module index: #{name} #{version} not indexed: #{inspect(why, limit: 5)}")
        :failed
    end
  rescue
    e ->
      Logger.warning("module index: #{name} not indexed: #{Exception.message(e)}")
      :failed
  end

  # A tarball larger than `big_parse_bytes` compressed is parsed while no
  # other large one is (a node-local lock): aws's 4.9 MB tarball parses at
  # about 230 MB, so four at once could near 1 GB on the web host; smaller
  # ones go on at up to `max_concurrency/0` at once.
  defp read_release(name, version, reader) do
    with {:ok, bytes} <- reader.tarball.(name, version),
         {:ok, sum} <- reader.checksum.(name, version),
         true <- :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == sum do
      parse = fn -> reader.read.(bytes, max_tarball: @max_tarball_bytes) end

      if byte_size(bytes) > reader.big,
        do: :global.trans({{__MODULE__, :big_parse}, self()}, parse, [node()]),
        else: parse.()
    end
  end

  # The module names our passing builds of the package wrote (R3-5b), any
  # version and every config_variant (each one's modules count): a module a
  # macro defines, or a leex/yecc file's.
  defp manifest_modules(name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT e->>'path'
        FROM catalog_toolchain_builds t
        JOIN catalog_packages p ON p.id = t.package_id
        CROSS JOIN LATERAL jsonb_array_elements(
          CASE WHEN jsonb_typeof(t.file_manifest->'ebin') = 'array' THEN t.file_manifest->'ebin'
               ELSE '[]'::jsonb END) e
        WHERE p.name = $1 AND t.status = 'pass'
        """,
        [name]
      )

    for [path] <- rows,
        is_binary(path),
        String.ends_with?(path, ".beam"),
        do: Path.basename(path, ".beam")
  end

  defp store(name, {version, stable}, generation, app, modules) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM catalog_module_definers WHERE package = $1", [name])
        insert_definers(name, modules)

        Repo.query!(
          """
          INSERT INTO catalog_module_index_packages
            (package, version, stable, modules, refreshed_at, generation, app)
          VALUES ($1, $2, $6, $3, now(), $4, $5)
          ON CONFLICT (package) DO UPDATE
          SET version = EXCLUDED.version, stable = EXCLUDED.stable, modules = EXCLUDED.modules,
              refreshed_at = now(), generation = EXCLUDED.generation, app = EXCLUDED.app
          """,
          [name, version, length(modules), generation, app, stable]
        )

        :ok
      end)

    :indexed
  end

  defp insert_definers(name, modules) do
    modules
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        "catalog_module_definers",
        Enum.map(chunk, &%{module: &1, package: name}),
        on_conflict: :nothing
      )
    end)
  end

  # --- builds refused while the index was not complete (R5-5) -------------------

  @not_complete "(module index not complete)"

  @doc """
  Queues again, once, the toolchain build of every live row at the current
  builder version that ingest stored `skipped` only because the index was
  not complete (its reason ends in `#{@not_complete}`; round 6, R5-5), so
  such a refusal is no final verdict: `refresh/1` calls it after each
  complete run. The job is unique while it waits, so a later run does not
  queue it twice; its rebuild is judged by the complete index. Returns how
  many it queued. Pinned and host-native builds and `pure_elixir` results
  refused that way are not queued here (see the otp-probe report, round 6).
  """
  @spec requeue_not_complete() :: non_neg_integer()
  def requeue_not_complete do
    bv = Portal.Toolchains.builder_version()
    images = Map.new(Portal.Toolchains.images(), &{&1.toolchain, &1.image})

    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.name, t.version, t.toolchain, t.variant::text, t.config_variant
        FROM catalog_toolchain_builds t JOIN catalog_packages p ON p.id = t.package_id
        WHERE t.builder_version = $1 AND t.status = 'skipped' AND t.revoked_at IS NULL
          AND t.reason LIKE $2
        """,
        [bv, "%" <> @not_complete]
      )

    queue_for = Portal.Toolchains.MemoryRouting.router(rows |> Enum.map(&hd/1) |> Enum.uniq())

    Enum.count(rows, fn [name, version, toolchain, variant, config_variant] ->
      with image when is_binary(image) <- Map.get(images, toolchain),
           {:ok, %Oban.Job{conflict?: false}} <-
             %{
               package: name,
               version: version,
               toolchain: toolchain,
               image: image,
               builder_version: bv,
               variant: variant,
               config_variant: config_variant,
               reason: "module_index_complete"
             }
             |> Portal.Workers.ToolchainBuild.new(priority: 3, queue: queue_for.(name))
             |> Oban.insert() do
        true
      else
        _ -> false
      end
    end)
  end

  # --- recheck (R3-5a) ---------------------------------------------------------

  # Every served row, of every toolchain config_variant: each is served.
  # `{kind, table, served rows with a record (id, records, lock), revoked-at
  # column, reason column}`; a `pure_elixir` result keeps its record in a
  # column of its own (round 6, R5-6).
  # S10: a row whose `compile_inputs` hold a module probe is checked too.
  @record_where "(jsonb_typeof(RECORDS) = 'array' AND jsonb_array_length(RECORDS) > 0) OR " <>
                  "EXISTS (SELECT 1 FROM unnest(INPUTS) i " <>
                  "WHERE i->>'kind' = 'probe' AND i->>'of' = 'module')"
  @recheck_kinds [
    {"toolchain_build", "catalog_toolchain_builds",
     "SELECT t.id, t.compile_observations->'declared_absent', t.deps_lock, t.compile_inputs " <>
       "FROM catalog_toolchain_builds t " <>
       "WHERE t.revoked_at IS NULL AND t.status = 'pass' AND (" <>
       (@record_where
        |> String.replace("RECORDS", "t.compile_observations->'declared_absent'")
        |> String.replace("INPUTS", "t.compile_inputs")) <> ")", "revoked_at", "revoked_reason"},
    {"pinned_build", "catalog_pinned_builds",
     "SELECT t.id, t.compile_observations->'declared_absent', t.deps_lock, t.compile_inputs " <>
       "FROM catalog_pinned_builds t " <>
       "WHERE t.revoked_at IS NULL AND t.status = 'pass' AND (" <>
       (@record_where
        |> String.replace("RECORDS", "t.compile_observations->'declared_absent'")
        |> String.replace("INPUTS", "t.compile_inputs")) <> ")", "revoked_at", "revoked_reason"},
    {"host_native_build", "catalog_host_native_builds",
     "SELECT t.id, t.compile_observations->'declared_absent', t.deps_lock, t.compile_inputs " <>
       "FROM catalog_host_native_builds t " <>
       "WHERE t.revoked_at IS NULL AND t.status = 'pass' AND (" <>
       (@record_where
        |> String.replace("RECORDS", "t.compile_observations->'declared_absent'")
        |> String.replace("INPUTS", "t.compile_inputs")) <> ")", "revoked_at", nil},
    {"system_result", "catalog_system_results",
     "SELECT t.id, t.declared_absent, coalesce(t.deps_lock, r.deps_lock), t.compile_inputs " <>
       "FROM catalog_system_results t " <>
       "JOIN catalog_runs r ON r.id = t.run_id " <>
       "WHERE t.unpublished_at IS NULL AND t.status = 'pass' AND t.system_pkg = 'pure_elixir' AND (" <>
       (@record_where
        |> String.replace("RECORDS", "t.declared_absent")
        |> String.replace("INPUTS", "t.compile_inputs")) <> ")", "unpublished_at",
     "unpublished_reason"}
  ]

  @doc """
  Re-checks every served toolchain, pinned and host-native build, and
  every served `pure_elixir` result, whose judge recorded declared-absent
  probes against the index as it is now,
  and withholds (revokes) each one that now collides, tagged with the
  generation (`withheld_reason/1`) and listed in
  `catalog_module_index_withheld` for `undo_recheck/1`. Only on a complete
  index. `dry_run: true` counts without writing. Returns `%{withheld,
  checked, by_kind}`.
  """
  @spec recheck(keyword()) :: %{atom() => term()}
  def recheck(opts \\ []) do
    generation = Keyword.get_lazy(opts, :generation, fn -> latest_run()[:generation] end)
    dry_run = Keyword.get(opts, :dry_run, false)

    if complete?() do
      found =
        for {kind, _table, select, _at, _reason} <- @recheck_kinds,
            [id, items, lock, inputs] <- served_with_records(select),
            refusal = refusal(items, lock_keys(lock), inputs),
            refusal != nil,
            do: {kind, Ecto.UUID.load!(id), refusal}

      checked = count_with_records()

      # A dry run writes nothing, not even the run's count (round 6, R5-7).
      unless dry_run do
        withhold(found, generation)

        Repo.query!("UPDATE catalog_module_index_runs SET withheld = $2 WHERE generation = $1", [
          generation,
          length(found)
        ])
      end

      %{
        withheld: length(found),
        checked: checked,
        by_kind: Enum.frequencies_by(found, &elem(&1, 0))
      }
    else
      %{withheld: 0, checked: 0, by_kind: %{}, skipped: :not_complete}
    end
  end

  @doc "The revocation reason a recheck of `generation` writes."
  @spec withheld_reason(pos_integer()) :: String.t()
  def withheld_reason(generation),
    do: "declared-absent probe collides (module index generation #{generation})"

  # The table and column names come from @recheck_kinds, never from input.
  # sobelow_skip ["SQL.Query"]
  defp served_with_records(select) do
    %{rows: rows} = Repo.query!(select, [], timeout: 600_000)
    rows
  end

  defp count_with_records do
    Enum.sum(
      for {_kind, _table, select, _at, _reason} <- @recheck_kinds,
          do: length(served_with_records(select))
    )
  end

  defp lock_keys(%{} = lock), do: Map.keys(lock)
  defp lock_keys(_lock), do: []

  defp withhold(found, generation) do
    reason = withheld_reason(generation)

    {:ok, :ok} =
      Repo.transaction(fn ->
        Enum.each(found, &withhold_row(&1, generation, reason))
        :ok
      end)

    if found != [],
      do:
        Logger.warning(
          "module index: recheck of generation #{generation} withheld #{length(found)} rows"
        )
  end

  # The table and column names come from @recheck_kinds, never from input.
  # sobelow_skip ["SQL.Query"]
  # The row's revoked-at and the entry's withheld_at are the same instant,
  # and the entry is written only when the UPDATE took the row, so the undo
  # can match its own withholding exactly (round 6, R5-7).
  defp withhold_row({kind, id, refusal}, generation, reason) do
    {^kind, table, _select, at, reason_col} = List.keyfind(@recheck_kinds, kind, 0)
    set = if reason_col, do: "#{at} = $3, #{reason_col} = $2", else: "#{at} = $3, id = id"
    now = DateTime.utc_now()

    %{num_rows: taken} =
      Repo.query!(
        "UPDATE #{table} SET #{set}, updated_at = $3 WHERE id = $1 AND #{at} IS NULL AND $2::text IS NOT NULL",
        [Ecto.UUID.dump!(id), reason, now]
      )

    if taken == 1 do
      Repo.query!(
        """
        INSERT INTO catalog_module_index_withheld (generation, kind, row_id, withheld_at, reason)
        VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING
        """,
        [generation, kind, Ecto.UUID.dump!(id), now, refusal]
      )
    end
  end

  @doc """
  Undoes a recheck's withholding: the rows `catalog_module_index_withheld`
  lists for `generation` that are still revoked by it are served again.
  Returns how many per kind.
  """
  @spec undo_recheck(pos_integer()) :: %{String.t() => non_neg_integer()}
  def undo_recheck(generation) do
    reason = withheld_reason(generation)

    {:ok, counts} =
      Repo.transaction(fn ->
        Map.new(@recheck_kinds, &undo_kind(&1, generation, reason))
      end)

    counts
  end

  # The table and column names come from @recheck_kinds, never from input.
  # sobelow_skip ["SQL.Query"]
  # Only this generation's own withholding: its reason where the table has
  # one, and always the very instant it revoked the row (a later revocation
  # by anything else has another), which host-native rows, without a reason
  # column, rely on.
  defp undo_kind({kind, table, _select, at, reason_col}, generation, reason) do
    match = if reason_col, do: "AND t.#{reason_col} = $2", else: "AND $2::text IS NOT NULL"
    clear = if reason_col, do: "#{at} = NULL, #{reason_col} = NULL", else: "#{at} = NULL"

    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE #{table} t SET #{clear}, updated_at = now()
        FROM catalog_module_index_withheld w
        WHERE w.generation = $1 AND w.kind = $3 AND w.row_id = t.id
          AND t.#{at} = w.withheld_at #{match}
        """,
        [generation, reason, kind]
      )

    {kind, n}
  end
end
