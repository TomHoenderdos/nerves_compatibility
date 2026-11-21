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
  generation of its own. It reads the latest release of every candidate
  (`hex_downloads_recent >= min_recent/0`), its tarball checked against the
  registry's outer checksum, and takes the union of the modules its sources
  define (`Compatibility.HexModules`: literal definitions, leex and yecc
  files) and of the module names in our own passing builds' manifests of the
  package (R3-5b: modules a macro defines). A package already indexed at
  that release is confirmed without a fetch. The index is usable only when
  its latest run confirmed every candidate (`complete?/0`). Until then (no
  run yet, a run still going or stopped, a failed fetch or checksum, a
  tarball over the caps), every recorded declared-absent probe refuses. A
  newer run supersedes an older one, which stops at its next package.

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

  @doc "The recent-download count from which another package defining a probed module refuses."
  @spec min_recent() :: pos_integer()
  def min_recent, do: @min_recent

  @doc "The most packages `refresh/1` fetches and parses at once."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: @max_concurrency

  @doc "Whether the latest run confirmed every candidate: the only state in which `refusal/2` decides by the index."
  @spec complete?() :: boolean()
  def complete? do
    case latest_run() do
      %{complete: complete} -> complete
      nil -> false
    end
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
  module and neither the item's `declared` packages, its `declared_apps`
  nor `locked` name the package or its application; any item while the
  index is not complete; a `truncated` item always.
  """
  @spec refusal([map()] | nil, [String.t()]) :: String.t() | nil
  def refusal(items, locked) when is_list(items) and items != [] do
    complete = complete?()
    Enum.find_value(items, &item_refusal(&1, MapSet.new(locked), complete))
  end

  def refusal(_items, _locked), do: nil

  defp item_refusal(%{"kind" => "truncated"}, _locked, _complete),
    do: Compatibility.Portability.dependency_probe() <> "too many declared-absent probes recorded"

  defp item_refusal(%{"kind" => "module_absent", "module" => module} = item, locked, complete)
       when is_binary(module) do
    via = if is_binary(item["via"]), do: item["via"], else: "a probe"

    named =
      [item["declared"], item["declared_apps"]]
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

  defp item_refusal(_item, _locked, _complete),
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

    * `dry_run: true` reads nothing from Hex and writes nothing: it returns
      `%{to_fetch, unchanged, below_threshold}`;
    * at most `max_concurrency/0` (4) packages are fetched and parsed at
      once (`:concurrency` may lower it, never raise it), each with its
      tarball in memory only while it is read (at most 16 MiB), and killed
      after 2 minutes;
    * each package is stored in a transaction of its own as soon as it is
      read, most downloaded first, so a run that is stopped keeps what it
      stored and the next run fetches only the rest (and confirms the rest
      without a fetch).

  Options: `:tarball` and `:outer_checksum` (`fn name, version -> {:ok,
  value} | {:error, why} end`, default `Portal.HexDeps`), `:limit`,
  `:concurrency`, `:dry_run`, `:recheck`.
  """
  @spec refresh(keyword()) :: %{atom() => term()}
  def refresh(opts \\ []) do
    rows = candidates(Keyword.get(opts, :limit, 100_000))

    {todo, unchanged} =
      Enum.split_with(rows, fn [_name, version, indexed] -> version != indexed end)

    if Keyword.get(opts, :dry_run, false) do
      %{to_fetch: length(todo), unchanged: length(unchanged), below_threshold: below_threshold()}
    else
      {:ok, generation} = start_run(length(rows))
      result = run(generation, rows, opts)
      finish(generation, rows, result, opts)
    end
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
    tarball =
      Keyword.get(opts, :tarball, &Portal.HexDeps.tarball(&1, &2, max_bytes: @max_tarball_bytes))

    checksum = Keyword.get(opts, :outer_checksum, &Portal.HexDeps.outer_checksum/2)

    concurrency =
      opts |> Keyword.get(:concurrency, @max_concurrency) |> min(@max_concurrency) |> max(1)

    rows
    |> Task.async_stream(
      fn [name, version, indexed] ->
        cond do
          superseded?(generation) -> :superseded
          version == indexed -> confirm(name, version, generation)
          true -> index_release(name, version, generation, tarball, checksum)
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
        JOIN catalog_packages p ON p.name = i.package
        WHERE i.package = ANY($1) AND i.generation = $2 AND i.version = p.hex_latest_version
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

    Map.merge(result, %{generation: generation, complete: complete, withheld: withheld})
  end

  defp superseded?(generation) do
    %{rows: [[latest]]} =
      Repo.query!("SELECT max(generation) FROM catalog_module_index_runs", [])

    latest != generation
  end

  defp candidates(limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.name, p.hex_latest_version, i.version
        FROM catalog_packages p
        LEFT JOIN catalog_module_index_packages i ON i.package = p.name
        WHERE coalesce(p.hex_downloads_recent, 0) >= $1 AND p.hex_latest_version IS NOT NULL
        ORDER BY p.hex_downloads_recent DESC, p.name
        LIMIT $2
        """,
        [@min_recent, limit]
      )

    rows
  end

  defp below_threshold do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM catalog_packages
        WHERE coalesce(hex_downloads_recent, 0) < $1 AND hex_latest_version IS NOT NULL
        """,
        [@min_recent]
      )

    n
  end

  # Indexed already at this release: confirmed in this generation, with the
  # module names of builds made since added.
  defp confirm(name, version, generation) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        insert_definers(name, manifest_modules(name))

        Repo.query!(
          "UPDATE catalog_module_index_packages SET generation = $3 WHERE package = $1 AND version = $2",
          [name, version, generation]
        )

        :ok
      end)

    :unchanged
  end

  defp index_release(name, version, generation, tarball, checksum) do
    with {:ok, bytes} <- tarball.(name, version),
         {:ok, sum} <- checksum.(name, version),
         true <- :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == sum,
         {:ok, %{modules: modules, app: app}} <-
           Compatibility.HexModules.read(bytes, max_tarball: @max_tarball_bytes) do
      store(name, version, generation, app, Enum.uniq(modules ++ manifest_modules(name)))
    else
      why ->
        Logger.warning("module index: #{name} #{version} not indexed: #{inspect(why, limit: 5)}")
        :failed
    end
  rescue
    e ->
      Logger.warning("module index: #{name} #{version} not indexed: #{Exception.message(e)}")
      :failed
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

  defp store(name, version, generation, app, modules) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM catalog_module_definers WHERE package = $1", [name])
        insert_definers(name, modules)

        Repo.query!(
          """
          INSERT INTO catalog_module_index_packages (package, version, modules, refreshed_at, generation, app)
          VALUES ($1, $2, $3, now(), $4, $5)
          ON CONFLICT (package) DO UPDATE
          SET version = EXCLUDED.version, modules = EXCLUDED.modules, refreshed_at = now(),
              generation = EXCLUDED.generation, app = EXCLUDED.app
          """,
          [name, version, length(modules), generation, app]
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

  # --- recheck (R3-5a) ---------------------------------------------------------

  # Every served row, of every toolchain config_variant: each is served.
  @recheck_kinds [
    {"toolchain_build", "catalog_toolchain_builds", "t.revoked_at IS NULL AND t.status = 'pass'",
     "revoked_at", "revoked_reason"},
    {"pinned_build", "catalog_pinned_builds", "t.revoked_at IS NULL AND t.status = 'pass'",
     "revoked_at", "revoked_reason"},
    {"host_native_build", "catalog_host_native_builds",
     "t.revoked_at IS NULL AND t.status = 'pass'", "revoked_at", nil}
  ]

  @doc """
  Re-checks every served toolchain, pinned and host-native build whose
  judge recorded declared-absent probes against the index as it is now,
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
        for {kind, table, served, _at, _reason} <- @recheck_kinds,
            [id, items, lock] <- served_with_records(table, served),
            refusal = refusal(items, lock_keys(lock)),
            refusal != nil,
            do: {kind, Ecto.UUID.load!(id), refusal}

      checked = count_with_records()
      unless dry_run, do: withhold(found, generation)

      Repo.query!("UPDATE catalog_module_index_runs SET withheld = $2 WHERE generation = $1", [
        generation,
        if(dry_run, do: nil, else: length(found))
      ])

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
  defp served_with_records(table, served) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t.id, t.compile_observations->'declared_absent', t.deps_lock FROM #{table} t
        WHERE #{served} AND jsonb_typeof(t.compile_observations->'declared_absent') = 'array'
          AND jsonb_array_length(t.compile_observations->'declared_absent') > 0
        """,
        [],
        timeout: 600_000
      )

    rows
  end

  defp count_with_records do
    Enum.sum(
      for {_kind, table, served, _at, _reason} <- @recheck_kinds,
          do: length(served_with_records(table, served))
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
  defp withhold_row({kind, id, refusal}, generation, reason) do
    {^kind, table, _served, at, reason_col} = List.keyfind(@recheck_kinds, kind, 0)
    set = if reason_col, do: "#{at} = now(), #{reason_col} = $2", else: "#{at} = now()"

    Repo.query!(
      "UPDATE #{table} SET #{set}, updated_at = now() WHERE id = $1 AND #{at} IS NULL",
      if(reason_col, do: [Ecto.UUID.dump!(id), reason], else: [Ecto.UUID.dump!(id)])
    )

    Repo.query!(
      """
      INSERT INTO catalog_module_index_withheld (generation, kind, row_id, withheld_at, reason)
      VALUES ($1, $2, $3, now(), $4) ON CONFLICT DO NOTHING
      """,
      [generation, kind, Ecto.UUID.dump!(id), refusal]
    )
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
  defp undo_kind({kind, table, _served, at, reason_col}, generation, reason) do
    match = if reason_col, do: "AND t.#{reason_col} = $2", else: "AND $2::text IS NOT NULL"
    clear = if reason_col, do: "#{at} = NULL, #{reason_col} = NULL", else: "#{at} = NULL"

    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE #{table} t SET #{clear}, updated_at = now()
        FROM catalog_module_index_withheld w
        WHERE w.generation = $1 AND w.kind = $3 AND w.row_id = t.id
          AND t.#{at} IS NOT NULL #{match}
        """,
        [generation, reason, kind]
      )

    {kind, n}
  end
end
