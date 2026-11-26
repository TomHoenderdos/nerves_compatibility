defmodule Portal.Catalog.ReleaseIndex do
  @moduledoc """
  The module index per Hex release (S10 round 5): which modules every
  release of every Hex package defines, for client 0.10's
  declared-optional-dependency rule.

  A `probe` compile input with `declared` (`Compatibility.CompileInputs`)
  holds in a user's project when no dependency at its locked version
  defines the probed module and every dependency's release is one this
  index has read. The client decides that itself, from two things each
  signed batch names under `release_index` (`render_docs/0`):

    * the read releases, in 256 shards by the first byte of the SHA-256 of
      the package name (`shard/1`), each `%{package => [[version, outer
      checksum]]}`: a release is known by the tarball it was read from, so
      to a client whose lock has another outer checksum for it (a release
      replaced with `mix hex.publish --replace` since) it is unread (review
      F2). A release read within the last three hours is read again when
      the registry's checksum for it changes;
    * one definer set per probed module (`catalog_release_probed_modules`,
      filled at ingest), `%{package => [version that defines it]}`.

  Both come from one statement, so one snapshot of the index: a release is
  in the read set exactly when its definers are in the sets, from the same
  tarball. So the portal needs no global completeness
  for these items, and nothing is re-checked or withheld when the index
  grows: the next batch carries the new set, and the client decides each
  user's lock.

  **What a release defines** (`Compatibility.HexModules`): the literal
  `defmodule`, `defprotocol` and `defimpl` names of the sources Mix or
  rebar3 compiles (every source when a build script or hook can compile
  more: gpb's `descr_src/`), and every Erlang module by its file, plus the
  module names our passing toolchain and pinned host builds of that release
  wrote (`add_build_modules/3`: ebin and `defined_modules`). A release whose
  tarball cannot be read (a failed fetch or checksum, over the caps, a
  source read that does not parse, an EEx template outside `lib/` aside)
  is `failed`, never read, so a client with it locked misses; the daily run
  tries it again.

  **Runs** (`refresh/1`). The registry (`Portal.HexRegistry`, every
  package's every version, signed by hex.pm) is the list of releases, not
  the catalog (review U3). A run reads every release it does not hold yet,
  at most #{4} packages at once (each package's registry entry once, for
  its outer checksums, then its releases one by one, each tarball checked
  against its checksum and held in memory only while it is parsed; a
  tarball over 1 MiB compressed is parsed while no other such one is), and
  stores each release in a transaction of its own as soon as it is read,
  so a run that is stopped keeps what it stored and the next one reads only
  the rest. The first run reads every release (184,566 on 2026-11-26);
  `Portal.Workers.UpdateCheck` then queues an incremental run hourly when
  the registry lists a release this index has not tried
  (`queue_incremental/1`), and the daily run retries the failed ones.
  """

  alias Portal.Repo

  require Logger

  @max_concurrency 4
  @max_tarball_bytes 16 * 1024 * 1024
  @big_parse_bytes 1024 * 1024
  @package_timeout_ms 30 * 60 * 1000
  @shards for i <- 0..255, do: i |> :binary.encode_unsigned() |> Base.encode16(case: :lower)

  @doc "The most packages `refresh/1` reads at once."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: @max_concurrency

  @doc "The 256 shard names, `\"00\"` to `\"ff\"`."
  @spec shards() :: [String.t()]
  def shards, do: @shards

  @doc "The shard of `package`: the first byte of the SHA-256 of its name, in hex."
  @spec shard(String.t()) :: String.t()
  def shard(package) when is_binary(package),
    do: :crypto.hash(:sha256, package) |> binary_part(0, 1) |> Base.encode16(case: :lower)

  @doc """
  A run: reads every release the registry lists that this index has not
  read (or tried, unless `retry_failed: true`). Returns `%{packages, read,
  failed, to_read}`, or with `dry_run: true` only what it would read.

  Options: `:registry` (`fn -> {:ok, %{name => [version]}} | {:error, why}
  end`, default `Portal.HexRegistry.snapshot/1`), `:releases` (`fn name ->
  {:ok, [%{version, outer_checksum}]} | {:error, why} end`, default
  `Portal.HexDeps.releases/2`), `:tarball` (`fn name, version -> {:ok,
  bytes} | {:error, why} end`), `:read` (default
  `Compatibility.HexModules.read/2`), `:limit` (packages), `:concurrency`
  (at most #{@max_concurrency}), `:retry_failed`, `:dry_run`,
  `:big_parse_bytes`.
  """
  @spec refresh(keyword()) :: map()
  def refresh(opts \\ []) do
    registry = Keyword.get(opts, :registry, &registry/0)

    case registry.() do
      {:ok, listed} ->
        todo = todo(listed, Keyword.get(opts, :retry_failed, false), Keyword.get(opts, :limit))
        releases = todo |> Enum.map(&length(elem(&1, 1))) |> Enum.sum()

        if Keyword.get(opts, :dry_run, false),
          do: %{packages: length(todo), to_read: releases},
          else: Map.put(run(todo, opts), :to_read, releases)

      {:error, why} ->
        Logger.warning(
          "release index: the Hex registry could not be read: #{inspect(why, limit: 5)}"
        )

        %{error: why}
    end
  end

  defp registry do
    case Portal.HexRegistry.snapshot(all_versions: true) do
      {:ok, entries} -> {:ok, listed(entries)}
      {:error, _} = error -> error
    end
  end

  # `%{name => [version]}` from registry entries (their `versions`, else
  # their latest version alone).
  defp listed(entries) do
    Map.new(entries, fn entry ->
      {entry.name, List.wrap(Map.get(entry, :versions) || Map.get(entry, :latest_version))}
    end)
  end

  # `[{package, [version to read], %{version => outer checksum}}]`, packages
  # by name: the releases to read, and the ones read within the replace
  # window (review F2), with the checksum each was read at, to read again
  # when the registry's checksum differs.
  defp todo(listed, retry_failed, limit) do
    open = open(listed, retry_failed) |> Enum.group_by(&hd/1, &List.last/1)
    recent = recent(listed)

    (Map.keys(open) ++ Map.keys(recent))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, Enum.sort(Map.get(open, &1, [])), Map.get(recent, &1, %{})})
    |> then(&if(is_integer(limit), do: Enum.take(&1, limit), else: &1))
  end

  # The listed releases to read (re-review R5-4: an anti-join in the
  # database, not every index row in memory): untried, failed when retried,
  # or read before the index stored checksums.
  defp open(listed, retry_failed) do
    {packages, versions} =
      listed |> Enum.flat_map(fn {n, vs} -> Enum.map(vs, &{n, &1}) end) |> Enum.unzip()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT l.package, l.version
        FROM unnest($1::text[], $2::text[]) AS l(package, version)
        LEFT JOIN catalog_release_index i ON i.package = l.package AND i.version = l.version
        WHERE i.package IS NULL
           OR (i.state = 'read' AND i.outer_checksum IS NULL)
           OR (i.state = 'failed' AND $3)
        """,
        [packages, versions, retry_failed],
        timeout: 600_000
      )

    rows
  end

  # Hex lets a public release be replaced (`mix hex.publish --replace`)
  # within an hour of its publication, and the registry's CDN copy lags up
  # to an hour: a listed release read within the last three hours is
  # checked again, `%{package => %{version => outer checksum}}`.
  @replace_window_hours 3

  defp recent(listed) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT package, version, outer_checksum FROM catalog_release_index
        WHERE state = 'read' AND outer_checksum IS NOT NULL
          AND tried_at > now() - make_interval(hours => $1)
        """,
        [@replace_window_hours]
      )

    for [p, v, outer] <- rows, v in Map.get(listed, p, []), reduce: %{} do
      acc -> Map.update(acc, p, %{v => outer}, &Map.put(&1, v, outer))
    end
  end

  defp run(todo, opts) do
    reader = %{
      releases: Keyword.get(opts, :releases, &Portal.HexDeps.releases(&1, cache: false)),
      tarball:
        Keyword.get(
          opts,
          :tarball,
          &Portal.HexDeps.tarball(&1, &2, max_bytes: @max_tarball_bytes, cache: false)
        ),
      read: Keyword.get(opts, :read, &Compatibility.HexModules.read/2),
      big: Keyword.get(opts, :big_parse_bytes, @big_parse_bytes)
    }

    concurrency =
      opts |> Keyword.get(:concurrency, @max_concurrency) |> min(@max_concurrency) |> max(1)

    todo
    |> Task.async_stream(
      fn {name, versions, recent} -> read_package(name, versions, recent, reader) end,
      max_concurrency: concurrency,
      timeout: @package_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{packages: 0, read: 0, failed: 0}, fn
      {:ok, {read, failed}}, acc ->
        %{acc | packages: acc.packages + 1, read: acc.read + read, failed: acc.failed + failed}

      _killed, acc ->
        %{acc | packages: acc.packages + 1}
    end)
  end

  # Each release of a package, one after another: `{read, failed}`. A
  # release read within the replace window whose registry checksum is no
  # longer the one it was read at (review F2) is read again.
  defp read_package(name, versions, recent, reader) do
    checksums =
      case reader.releases.(name) do
        {:ok, releases} -> Map.new(releases, &{&1.version, &1.outer_checksum})
        {:error, why} -> {:error, why}
      end

    replaced =
      case checksums do
        %{} -> for {v, outer} <- recent, Map.get(checksums, v) not in [nil, outer], do: v
        _ -> []
      end

    Enum.reduce(Enum.sort(versions ++ replaced), {0, 0}, fn version, {read, failed} ->
      case read_release(name, version, checksums, reader) do
        {:ok, %{modules: modules, app: app}} ->
          store_read(name, version, app, modules, Map.get(checksums, version))
          {read + 1, failed}

        why ->
          record_failure(name, version, why)
          {read, failed + 1}
      end
    end)
  rescue
    e ->
      Logger.warning("release index: #{name} not read: #{Exception.message(e)}")
      {0, 0}
  end

  defp read_release(_name, _version, {:error, why}, _reader), do: {:error, {:registry, why}}

  defp read_release(name, version, checksums, reader) do
    with sum when is_binary(sum) <- Map.get(checksums, version) || {:error, :no_checksum},
         {:ok, bytes} <- reader.tarball.(name, version),
         true <- sha256(bytes) == sum || {:error, :checksum_mismatch} do
      parse = fn -> reader.read.(bytes, max_tarball: @max_tarball_bytes) end

      if byte_size(bytes) > reader.big,
        do: :global.trans({{__MODULE__, :big_parse}, self()}, parse, [node()]),
        else: parse.()
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # Our build lists are read after the delete, in the same transaction
  # (re-review R5-3): a build an ingest adds in between is either read here
  # or inserted after the delete, never deleted.
  defp store_read(name, version, app, modules, outer) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM catalog_release_definers WHERE package = $1 AND version = $2", [
          name,
          version
        ])

        insert_definers(name, version, Enum.uniq(modules ++ build_modules(name, version)))

        Repo.query!(
          """
          INSERT INTO catalog_release_index
            (package, version, state, reason, app, modules, outer_checksum, tried_at)
          VALUES ($1, $2, 'read', NULL, $3, $4, $5, now())
          ON CONFLICT (package, version) DO UPDATE
          SET state = 'read', reason = NULL, app = EXCLUDED.app, modules = EXCLUDED.modules,
              outer_checksum = EXCLUDED.outer_checksum, tried_at = now()
          """,
          [name, version, app, length(modules), outer]
        )

        :ok
      end)
  end

  # Only a failure of the release itself is recorded; one that says "ask
  # later" (the registry or the CDN unavailable, the node stopping under the
  # run) leaves it untried, for the next run.
  defp record_failure(name, version, why) do
    if transient?(why),
      do:
        Logger.warning(
          "release index: #{name} #{version} left for later: #{inspect(why, limit: 5)}"
        ),
      else: store_failed(name, version, why)
  end

  defp transient?({:error, :hex_registry_unavailable}), do: true
  defp transient?({:error, {:registry, _why}}), do: true
  defp transient?({:error, {:raised, _message}}), do: true
  defp transient?(_why), do: false

  defp store_failed(name, version, why) do
    Logger.warning("release index: #{name} #{version} not read: #{inspect(why, limit: 5)}")

    Repo.query!(
      """
      INSERT INTO catalog_release_index (package, version, state, reason, modules, tried_at)
      VALUES ($1, $2, 'failed', $3, 0, now())
      ON CONFLICT (package, version) DO UPDATE
      SET state = CASE WHEN catalog_release_index.state = 'read' THEN 'read' ELSE 'failed' END,
          reason = EXCLUDED.reason,
          tried_at =
            CASE WHEN catalog_release_index.state = 'read' THEN catalog_release_index.tried_at
            ELSE now() END
      """,
      [name, version, inspect(why, limit: 5) |> String.slice(0, 500)]
    )
  end

  defp insert_definers(name, version, modules) do
    modules
    |> Enum.filter(&Compatibility.CompileInputs.module_name?/1)
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        "catalog_release_definers",
        Enum.map(chunk, &%{module: &1, package: name, version: version}),
        on_conflict: :nothing
      )
    end)
  end

  # The module names our passing builds of this release wrote: their ebin
  # and their `defined_modules`, toolchain and pinned host builds alike, of
  # every config_variant (each one's modules count).
  defp build_modules(name, version) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT m FROM (
          SELECT regexp_replace(e->>'path', '^.*/|\\.beam$', '', 'g') AS m
          FROM catalog_toolchain_builds t JOIN catalog_packages p ON p.id = t.package_id
          CROSS JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_typeof(t.file_manifest->'ebin') = 'array' THEN t.file_manifest->'ebin'
                 ELSE '[]'::jsonb END) e
          WHERE p.name = $1 AND t.version = $2 AND t.status = 'pass' AND e->>'path' LIKE '%.beam'
          UNION
          SELECT regexp_replace(e->>'path', '^.*/|\\.beam$', '', 'g')
          FROM catalog_pinned_builds b JOIN catalog_packages p ON p.id = b.package_id
          CROSS JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_typeof(b.file_manifest->'ebin') = 'array' THEN b.file_manifest->'ebin'
                 ELSE '[]'::jsonb END) e
          WHERE p.name = $1 AND b.version = $2 AND b.status = 'pass' AND e->>'path' LIKE '%.beam'
          UNION
          SELECT unnest(t.defined_modules) FROM catalog_toolchain_builds t
          JOIN catalog_packages p ON p.id = t.package_id
          WHERE p.name = $1 AND t.version = $2 AND t.status = 'pass'
          UNION
          SELECT unnest(b.defined_modules) FROM catalog_pinned_builds b
          JOIN catalog_packages p ON p.id = b.package_id
          WHERE p.name = $1 AND b.version = $2 AND b.status = 'pass'
        ) found
        """,
        [name, version]
      )

    for [m] <- rows, is_binary(m), m != "", do: m
  end

  @doc """
  Adds the modules a passing build of `package` at `version` wrote (its
  ebin and `defined_modules`) to that release's definers, read or not yet:
  a module a macro defines is in no tarball parse. Ingest calls it.
  """
  @spec add_build_modules(String.t(), String.t(), [String.t()]) :: :ok
  def add_build_modules(package, version, modules)
      when is_binary(package) and is_binary(version) and is_list(modules) do
    insert_definers(package, version, Enum.filter(modules, &is_binary/1))
    :ok
  end

  def add_build_modules(_package, _version, _modules), do: :ok

  @doc """
  Queues the incremental run when the registry `entries`
  (`Portal.HexRegistry.snapshot/1`'s, as `Portal.Workers.UpdateCheck`
  reads them hourly) list a release this index has not tried. Only once a
  run has read something; at most one such job waits. Returns how many
  releases are new. Never raises.
  """
  @spec queue_incremental([map()]) :: non_neg_integer()
  def queue_incremental(entries) when is_list(entries) do
    if started?() do
      todo = entries |> listed() |> todo(false, nil)
      new = todo |> Enum.map(&length(elem(&1, 1))) |> Enum.sum()

      # A release read within the replace window is checked again hourly.
      if new > 0 or Enum.any?(todo, &(elem(&1, 2) != %{})),
        do: Oban.insert(Portal.Workers.ReleaseIndexRefresh.new(%{"incremental" => true}))

      new
    else
      0
    end
  rescue
    e ->
      Logger.warning("release index: no incremental run queued: #{Exception.message(e)}")
      0
  end

  def queue_incremental(_entries), do: 0

  defp started? do
    %{rows: [[started]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM catalog_release_index WHERE state = 'read')", [])

    started
  end

  @doc """
  The review gate's index-visible parts for a declared package (S10 round
  3, now per release): some read release of `package` defines `module`,
  and the module is in its namespace (it defines the module's first
  segment; an Erlang module is its application or starts with it and `_`).
  """
  @spec gate?(String.t(), String.t()) :: boolean()
  def gate?(module, package) when is_binary(module) and is_binary(package) do
    defines?(module, package) and namespace?(module, package)
  end

  defp defines?(module, package) do
    %{rows: [[found]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM catalog_release_definers d
          JOIN catalog_release_index i ON i.package = d.package AND i.version = d.version
          WHERE d.module = $1 AND d.package = $2 AND i.state = 'read')
        """,
        [module, package]
      )

    found
  end

  defp namespace?("Elixir." <> rest = module, package) do
    root = "Elixir." <> hd(String.split(rest, "."))
    root == module or defines?(root, package)
  end

  defp namespace?(module, package) do
    %{rows: rows} =
      Repo.query!(
        "SELECT DISTINCT app FROM catalog_release_index WHERE package = $1 AND state = 'read' AND app IS NOT NULL",
        [package]
      )

    apps = [package | List.flatten(rows)]
    Enum.any?(apps, &(module == &1 or String.starts_with?(module, &1 <> "_")))
  end

  @doc "Records `modules` as ones a served build's declared `probe` item names."
  @spec record_probed([String.t()]) :: :ok
  def record_probed([]), do: :ok

  def record_probed(modules) when is_list(modules) do
    Repo.insert_all(
      "catalog_release_probed_modules",
      for(
        m <- Enum.uniq(modules),
        is_binary(m),
        do: %{module: m, first_seen_at: DateTime.utc_now()}
      ),
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  The batch's `release_index` object and its documents, `{object, [{sha,
  body}]}`, or `nil` before any release was read: the read set in 256
  shards and each probed module's definer set, from one snapshot of the
  index (see the moduledoc).
  """
  @spec render_docs() :: {map(), [{String.t(), binary()}]} | nil
  def render_docs do
    rows = snapshot() |> Enum.group_by(&hd/1, &tl/1)
    read = Map.get(rows, "r", [])

    if read == [] do
      nil
    else
      found = rows |> Map.get("d", []) |> Enum.group_by(&hd/1, fn [_m, p, v, _o] -> {p, v} end)
      sets = for [m | _] <- Map.get(rows, "p", []), into: %{}, do: {m, Map.get(found, m, [])}

      shard_docs =
        read
        |> Enum.group_by(fn [_, p, _v, _o] -> shard(p) end, fn [_, p, v, o] -> {p, [v, o]} end)
        |> then(fn by_shard -> Map.new(@shards, &{&1, Map.get(by_shard, &1, [])}) end)
        |> Map.new(fn {shard, pairs} ->
          {shard, doc(%{"format" => 1, "shard" => shard, "read" => by_package(pairs)})}
        end)

      module_docs =
        Map.new(sets, fn {module, pairs} ->
          {module, doc(%{"format" => 1, "module" => module, "definers" => by_package(pairs)})}
        end)

      object = %{
        "format" => 1,
        "shards" => Map.new(shard_docs, fn {s, {sha, _}} -> {s, sha} end),
        "modules" => Map.new(module_docs, fn {m, {sha, _}} -> {m, sha} end)
      }

      {object, Map.values(shard_docs) ++ Map.values(module_docs)}
    end
  end

  # The read releases (`["r", nil, package, version, outer]`; one read
  # before the index stored checksums is left out until it is read again),
  # the probed modules (`["p", module, ...]`) and their definers among the
  # read releases (`["d", module, package, version, outer]`), in one
  # statement and so one snapshot: a release read again (replaced, review
  # F2) is in the read set and the sets at the same tarball, or in neither.
  defp snapshot do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 'r', NULL::text, package, version, outer_checksum FROM catalog_release_index
        WHERE state = 'read' AND outer_checksum IS NOT NULL
        UNION ALL
        SELECT 'p', module, NULL, NULL, NULL FROM catalog_release_probed_modules
        UNION ALL
        SELECT 'd', d.module, d.package, d.version, i.outer_checksum
        FROM catalog_release_definers d
        JOIN catalog_release_index i ON i.package = d.package AND i.version = d.version
        WHERE d.module IN (SELECT module FROM catalog_release_probed_modules)
          AND i.state = 'read' AND i.outer_checksum IS NOT NULL
        """,
        [],
        timeout: 600_000
      )

    rows
  end

  defp by_package(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {p, vs} -> {p, vs |> Enum.uniq() |> Enum.sort()} end)
  end

  defp doc(map) do
    body = canonical(map)
    {sha256(body), body}
  end

  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, value} ->
        JSON.encode!(to_string(key)) <> ":" <> canonical(value)
      end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value), do: JSON.encode!(value)

  @doc """
  Stores the documents of `render_docs/0`; one already there is kept, and
  marked as named (`named_at`, at most hourly). A document no batch named
  for three days (a batch expires after 24 h) is deleted (re-review R5-5).
  `Portal.Precompiled.Batches` calls it in the transaction that inserts the
  batch naming them. A few statements, not one per document.
  """
  @spec store_docs([{String.t(), binary()}]) :: :ok | {:error, term()}
  def store_docs(docs) do
    shas = Enum.map(docs, &elem(&1, 0))

    with {:ok, %{rows: rows}} <-
           Repo.query("SELECT sha256 FROM precompiled_release_docs WHERE sha256 = ANY($1)", [
             shas
           ]),
         have = MapSet.new(List.flatten(rows)),
         :ok <- insert_docs(for {sha, _} = doc <- docs, not MapSet.member?(have, sha), do: doc),
         {:ok, _} <-
           Repo.query(
             """
             UPDATE precompiled_release_docs SET named_at = now()
             WHERE sha256 = ANY($1) AND named_at < now() - interval '1 hour'
             """,
             [shas]
           ),
         {:ok, _} <-
           Repo.query(
             "DELETE FROM precompiled_release_docs WHERE named_at < now() - interval '3 days'",
             []
           ) do
      :ok
    end
  end

  # New documents, in chunks of 32 (a shard is tens of kB).
  defp insert_docs(docs) do
    now = DateTime.utc_now()

    docs
    |> Enum.chunk_every(32)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        "precompiled_release_docs",
        for(
          {sha, body} <- chunk,
          do: %{sha256: sha, body: body, inserted_at: now, named_at: now}
        ),
        on_conflict: :nothing,
        conflict_target: :sha256
      )
    end)
  rescue
    e -> {:error, e}
  end

  @doc "A stored document's bytes, only while they still hash to `sha`."
  @spec stored(String.t()) :: {:ok, binary()} | :error
  def stored(sha) when is_binary(sha) do
    with true <- Portal.ArtifactStore.valid_sha256?(sha),
         {:ok, %{rows: [[body]]}} <-
           Repo.query("SELECT body FROM precompiled_release_docs WHERE sha256 = $1", [sha]),
         true <- sha256(body) == sha do
      {:ok, body}
    else
      _ -> :error
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
