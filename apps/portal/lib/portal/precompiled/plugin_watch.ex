defmodule Portal.Precompiled.PluginWatch do
  @moduledoc """
  Serves a build that ran a rebar3 plugin only while every release Hex has
  of that plugin package, and of each plugin dependency the build ran, was
  reviewed (`Compatibility.RebarPlugins.reviewed?/2`; review S5 S1).

  ## Why

  rebar3 installs a dependency's `plugins` from Hex at whatever release its
  own registry cache resolves, with their dependencies, and no lock names
  them. The worker lets a build run only a pinned release
  (`NccWorker.Portability.RebarPlugins`), which guards our build. A user who
  compiles from source runs whatever release their rebar3 resolves: when a
  plugin publishes a release nobody reviewed, which could change what a
  compile produces, a build made with a reviewed one may no longer be what
  that user compiles. Such builds are withheld until the release is reviewed
  and pinned.

  ## How

    * Every build records the plugin releases it ran
      (`compile_observations.rebar3_plugins`); ingest copies them by run id,
      with the catalog package the build is of, into `rebar3_plugin_runs`
      (`record/3`), so an earlier build kept on a row is found by its own
      run, and a truncated observation map loses nothing.
    * `Portal.Workers.UpdateCheck` reads the whole registry every hour and
      writes, for each reviewed package, the releases Hex has that the review
      does not cover into `rebar3_plugin_watch` (`refresh/1`): any such
      release, the newest, a prerelease or a backport alike. A package the
      registry read does not list keeps what it had.
    * The guard fails closed (review S5 R4): while the newest refresh is
      older than `max_age_hours/0`, or there was none (the update check
      switched off with `NCC_UPDATE_CHECK=0`, the registry unreachable),
      every build that ran any plugin is withheld.
    * Every selector of published files leaves out a toolchain, pinned or
      host-native build whose run ran a watched package (`served_clause/1` in
      SQL, `withheld_runs/1` in Elixir). The watch entries of the plugin
      packages a package's runs ran, and the staleness while it has any
      record, are part of that package's manifest fingerprint
      (`fingerprint_sql/0`; review S5 N8): a change renders again only the
      packages that ran a plugin it touches. Deterministic siblings are
      served only beside their build.

  A build with no record that may have run a plugin, and that no requeue
  rebuilds, gets the withholding mark for its run (`mark_unrecorded/1`;
  review S5 S1): an earlier build a rebuild with another lock kept (its own
  run id stays served), a host-native build and a pinned host build. It may
  have run one when its compile fetched a plugin over TLS (the
  `pubkey_os_cacerts` mark in its `os_type_reads`), when it predates
  `os_type_reads` and its closure has a release whose config can run
  `rebar3_hex`, the one plugin a build judged before S5 could run
  (`Portal.Precompiled.PluginWatch.Declared`), or,
  for an earlier build of unknown origin, when its row's own build ran one.
  An earlier build keeps that fact from the build it was (`entry_fact/1`).
  The ingest marks its own row in its transaction (an earlier build at the
  push, a host-native or pinned host build when it lands), and the update
  check sweeps every hour, also while it is switched off, for what an older
  release wrote. A failed sweep is logged and emits
  `[:portal, :plugin_watch, :mark_unrecorded, :exception]` (review S5 final
  N1); the builds it would mark stay served until a sweep succeeds. Only
  rows an older release wrote depend on it, and withholding every build the
  sweep could not rule out while it fails would hide every legacy earlier
  build and pinned host build (2,096 and 496 on 2026-11-21) to protect the
  2 it marks.

  Reviewing a new release: the S5 design note's "Reviewing a new plugin
  release". Once a release that adds it to `Compatibility.RebarPlugins`
  deploys, the next update check clears the watch and the builds are served
  again; nothing is rebuilt.

  A current toolchain row made before builds recorded their plugins records
  none, so the watch cannot see it: such a build ran at most a `rebar3_hex`
  release (the only plugin the judge let through before), and the S5 requeue
  rebuilds it.
  """

  require Logger

  alias Compatibility.RebarPlugins
  alias Portal.Precompiled.PluginWatch.Declared

  # The oldest refresh the guard trusts (review S5 R4): the update check runs
  # hourly, so six missed runs.
  @max_age_hours 6

  # The SQL of `stale_sql/0` and of the record row predicate, literal and
  # fixed at compile time.
  @stale_sql "NOT EXISTS (SELECT 1 FROM rebar3_plugin_watch_state st " <>
               "WHERE st.key = 'refreshed' AND st.checked_at > " <>
               "(now() AT TIME ZONE 'utc') - interval '#{@max_age_hours} hours')"

  # Whether the record row aliased `bp` withholds its run: the mark, a
  # watched package, or any plugin while the watch is stale (review S5 R4).
  @withholds "(bp.package = '*' OR #{@stale_sql} OR EXISTS (SELECT 1 FROM " <>
               "rebar3_plugin_watch pw WHERE pw.package = bp.package))"

  @withheld_runs_sql "SELECT DISTINCT bp.run_id FROM rebar3_plugin_runs bp " <>
                       "WHERE bp.run_id = ANY($1::text[]) AND " <> @withholds

  @stale_query "SELECT " <> @stale_sql

  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+-]{0,63}\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  # The worker's bound (`NccWorker.Portability.RebarPlugins.max_releases/0`).
  @max_releases 64
  # The record of a run that ran plugin releases this cannot list: withheld
  # whatever the watch holds (`served_clause/1`).
  @unrecorded {"*", "unrecorded", nil}

  # The worker's cap on `os_type_reads` (`NccWorker.Portability`'s `@caps`):
  # a full list may have dropped the mark.
  @max_os_type_reads 50

  # SQL, literal and fixed at compile time. `@mark_of` takes the expression
  # of a build's `compile_observations` for `$X`: whether its compile
  # fetched a plugin over TLS.
  @mark_of "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN " <>
             "jsonb_typeof($X->'os_type_reads') = 'array' THEN $X->'os_type_reads' " <>
             "ELSE '[]'::jsonb END) o WHERE o->>'module' = 'pubkey_os_cacerts')"

  # Whether `os_type_reads` can show the mark's absence: recorded, under
  # the cap.
  @reads_known "(CASE WHEN jsonb_typeof($X->'os_type_reads') = 'array' " <>
                 "THEN jsonb_array_length($X->'os_type_reads') < #{@max_os_type_reads} " <>
                 "ELSE false END)"

  # Whether the closure of package `$N` version `$V` with lock `$L` holds a
  # release of `Declared` (`$1` names, `$2` versions).
  @declared_in "(EXISTS (SELECT 1 FROM unnest($1::text[], $2::text[]) AS d(name, version) " <>
                 "WHERE d.name = $N AND d.version = $V) OR EXISTS (SELECT 1 FROM " <>
                 "jsonb_each(CASE WHEN jsonb_typeof($L) = 'object' THEN $L ELSE '{}'::jsonb END) dl " <>
                 "JOIN unnest($1::text[], $2::text[]) AS d(name, version) " <>
                 "ON d.name = dl.key AND d.version = dl.value->>'version'))"

  # A build row with observations `$X` and closure `$N`/`$V`/`$L` that has no
  # record and may have run a plugin.
  @unrecorded_row "(NOT (coalesce($X, '{}'::jsonb) ? 'rebar3_plugins') AND (" <>
                    @mark_of <> " OR (NOT " <> @reads_known <> " AND " <> @declared_in <> ")))"

  @insert "INSERT INTO rebar3_plugin_runs (run_id, package, version, sha256, package_id) "
  @unmarked "AND NOT EXISTS (SELECT 1 FROM rebar3_plugin_runs x WHERE x.run_id = $R) "

  # An earlier build `e` of row `r` of package `p`, by its own fact
  # (`entry_fact/1`) or, without one, by its row's build and its closure.
  # Rows of every variant and config_variant alike: each earlier build is
  # served under its own run id whatever its row's identity.
  @earlier_sql @insert <>
                 "SELECT DISTINCT e->>'run_id', '*', 'unrecorded', NULL, r.package_id " <>
                 "FROM catalog_toolchain_builds r JOIN catalog_packages p ON p.id = r.package_id " <>
                 "CROSS JOIN LATERAL unnest(r.earlier_builds) AS e " <>
                 "WHERE cardinality(r.earlier_builds) > 0 " <>
                 "AND jsonb_typeof(e->'run_id') = 'string' AND e->>'run_id' <> '' " <>
                 "AND coalesce(e->>'plugins', 'unknown') NOT IN ('recorded', 'none') " <>
                 "AND (e->>'plugins' = 'mark' " <>
                 "OR " <>
                 String.replace(@mark_of, "$X", "r.compile_observations") <>
                 " OR (CASE WHEN jsonb_typeof(r.compile_observations->'rebar3_plugins') = 'array' " <>
                 "THEN jsonb_array_length(r.compile_observations->'rebar3_plugins') > 0 " <>
                 "ELSE false END) " <>
                 "OR " <>
                 (@declared_in
                  |> String.replace("$N", "p.name")
                  |> String.replace("$V", "r.version")
                  |> String.replace("$L", "e->'deps_lock'")) <>
                 ") " <> String.replace(@unmarked, "$R", "e->>'run_id'")

  @earlier_all_sql @earlier_sql <> "ON CONFLICT DO NOTHING"
  @earlier_row_sql @earlier_sql <> "AND r.id = $3 ON CONFLICT DO NOTHING"

  # A passing host-native build, and a passing pinned build the host built
  # (a firmware target's records no observations: stream S8's).
  @host_native_base @insert <>
                      "SELECT DISTINCT h.run_id, '*', 'unrecorded', NULL, h.package_id " <>
                      "FROM catalog_host_native_builds h JOIN catalog_packages p ON p.id = h.package_id " <>
                      "WHERE h.status = 'pass' AND h.revoked_at IS NULL AND h.run_id <> '' AND " <>
                      (@unrecorded_row
                       |> String.replace("$X", "h.compile_observations")
                       |> String.replace("$N", "p.name")
                       |> String.replace("$V", "h.version")
                       |> String.replace("$L", "h.deps_lock")) <>
                      " " <> String.replace(@unmarked, "$R", "h.run_id")

  @host_native_sql @host_native_base <> "ON CONFLICT DO NOTHING"
  @host_native_row_sql @host_native_base <> "AND h.id = $3 ON CONFLICT DO NOTHING"

  @pinned_base @insert <>
                 "SELECT DISTINCT pb.run_id, '*', 'unrecorded', NULL, pb.package_id " <>
                 "FROM catalog_pinned_builds pb JOIN catalog_packages p ON p.id = pb.package_id " <>
                 "WHERE pb.status = 'pass' AND pb.revoked_at IS NULL AND pb.run_id <> '' " <>
                 "AND pb.compile_observations IS NOT NULL AND " <>
                 (@unrecorded_row
                  |> String.replace("$X", "pb.compile_observations")
                  |> String.replace("$N", "p.name")
                  |> String.replace("$V", "pb.version")
                  |> String.replace("$L", "pb.deps_lock")) <>
                 " " <> String.replace(@unmarked, "$R", "pb.run_id")

  @pinned_sql @pinned_base <> "ON CONFLICT DO NOTHING"
  @pinned_row_sql @pinned_base <> "AND pb.id = $3 ON CONFLICT DO NOTHING"

  @doc "The oldest refresh, in hours, the guard trusts."
  @spec max_age_hours() :: pos_integer()
  def max_age_hours, do: @max_age_hours

  @doc "The most distinct plugin releases one run's record holds."
  @spec max_releases() :: pos_integer()
  def max_releases, do: @max_releases

  @doc """
  Records the plugin releases run `run_id` ran, a build of the catalog
  package `package_id`, from its build's
  `compile_observations` (`"rebar3_plugins"`: `%{"name", "version",
  "sha256"}` each). Deduplicated first and never cut (review S5 R3): a
  record of more than `max_releases/0` releases, or one with any malformed
  entry, records the withholding mark instead, `*`, which no watch state
  serves. Observations without the key record nothing (a build from before
  the record). Idempotent.
  """
  @spec record(Ecto.UUID.t(), String.t() | nil, term()) :: :ok
  def record(package_id, run_id, %{"rebar3_plugins" => plugins})
      when is_binary(run_id) and run_id != "" do
    package = Ecto.UUID.dump!(package_id)

    Enum.each(releases(plugins), fn {name, version, sha} ->
      Portal.Repo.query!(
        "INSERT INTO rebar3_plugin_runs (run_id, package, version, sha256, package_id) " <>
          "VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING",
        [run_id, name, version, sha, package]
      )
    end)
  end

  def record(_package_id, _run_id, _observations), do: :ok

  defp releases(plugins) when is_list(plugins) do
    parsed = Enum.map(plugins, &release/1)
    unique = parsed |> Enum.reject(&(&1 == :error)) |> Enum.uniq_by(&Tuple.delete_at(&1, 2))

    if :error in parsed or length(unique) > @max_releases, do: [@unrecorded], else: unique
  end

  defp releases(_plugins), do: [@unrecorded]

  defp release(%{"name" => name, "version" => version} = plugin)
       when is_binary(name) and is_binary(version) do
    if Regex.match?(@name, name) and Regex.match?(@version, version),
      do: {name, version, sha(plugin["sha256"])},
      else: :error
  end

  defp release(_plugin), do: :error

  defp sha(sha) when is_binary(sha), do: if(Regex.match?(@sha, sha), do: sha)
  defp sha(_sha), do: nil

  @doc """
  What an earlier build keeps of the plugins the build it was ran, from that
  build's `compile_observations` (review S5 S1): `"recorded"` (it has a
  record, which the watch serves it by), `"none"` (its compile fetched no
  plugin: `os_type_reads` recorded, under the cap, without the
  `pubkey_os_cacerts` mark), `"mark"` (it fetched one and has no record) or
  `"unknown"`.
  """
  @spec entry_fact(term()) :: String.t()
  def entry_fact(%{"rebar3_plugins" => _record}), do: "recorded"

  def entry_fact(%{"os_type_reads" => reads}) when is_list(reads) do
    cond do
      Enum.any?(reads, &match?(%{"module" => "pubkey_os_cacerts"}, &1)) -> "mark"
      length(reads) < @max_os_type_reads -> "none"
      true -> "unknown"
    end
  end

  def entry_fact(_observations), do: "unknown"

  @doc """
  Writes the withholding mark for every run with no record that may have
  run a plugin and that no requeue rebuilds (moduledoc). With an ingest's
  row, in its transaction (fail closed: a failure rolls the ingest back):
  `{:toolchain, id}` the earlier builds of a toolchain row, `{:host_native,
  id}` a host-native build, `{:pinned, id}` a pinned host build. With `nil`,
  the hourly sweep: those of every row, in one transaction, for what an
  older release wrote. Idempotent; a run that has a record or a mark is left
  alone.
  """
  @spec mark_unrecorded({:toolchain | :host_native | :pinned, Ecto.UUID.t()} | nil) :: :ok
  def mark_unrecorded(row \\ nil) do
    {names, versions} = Declared.columns()
    args = [names, versions]

    marked =
      case row do
        nil ->
          opts = [timeout: 120_000]

          {:ok, n} =
            Portal.Repo.transaction(fn ->
              Portal.Repo.query!(@earlier_all_sql, args, opts).num_rows +
                Portal.Repo.query!(@host_native_sql, args, opts).num_rows +
                Portal.Repo.query!(@pinned_sql, args, opts).num_rows
            end)

          n

        {:toolchain, id} ->
          Portal.Repo.query!(@earlier_row_sql, args ++ [Ecto.UUID.dump!(id)]).num_rows

        {:host_native, id} ->
          Portal.Repo.query!(@host_native_row_sql, args ++ [Ecto.UUID.dump!(id)]).num_rows

        {:pinned, id} ->
          Portal.Repo.query!(@pinned_row_sql, args ++ [Ecto.UUID.dump!(id)]).num_rows
      end

    :telemetry.execute([:portal, :plugin_watch, :mark_unrecorded], %{marked: marked}, %{})

    if marked > 0,
      do:
        Logger.warning("rebar3 plugin watch: #{marked} unrecorded builds withheld (review S5 S1)")

    :ok
  end

  @doc "The plugin releases run `run_id` ran, as `{package, version}`, sorted."
  @spec ran(String.t()) :: [{String.t(), String.t()}]
  def ran(run_id) do
    %{rows: rows} =
      Portal.Repo.query!(
        "SELECT package, version FROM rebar3_plugin_runs WHERE run_id = $1 " <>
          "ORDER BY package, version",
        [run_id]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @doc """
  Writes the watch from `registry` (`Portal.HexRegistry.snapshot/1` with
  `all_versions: true`): for each reviewed package the registry lists, the
  releases outside the review, or no row when there are none. A package it
  does not list keeps its row. Only a read that lists every reviewed package
  marks the watch fresh (review S5 N2): an empty or partial one says nothing
  about the packages it leaves out. Returns the watch as it is then:
  `%{package => [version]}`.
  """
  @spec refresh([map()]) :: %{String.t() => [String.t()]}
  def refresh(registry) do
    by_name = Map.new(registry, &{&1.name, &1})
    now = DateTime.utc_now()
    missing = Enum.reject(RebarPlugins.packages(), &Map.has_key?(by_name, &1))

    Portal.Repo.transaction(fn ->
      if missing == [] do
        Portal.Repo.query!(
          "INSERT INTO rebar3_plugin_watch_state (key, checked_at) VALUES ('refreshed', $1) " <>
            "ON CONFLICT (key) DO UPDATE SET checked_at = EXCLUDED.checked_at",
          [now]
        )
      end

      for package <- RebarPlugins.packages(), entry = by_name[package], entry != nil do
        versions = Map.get(entry, :versions) || [entry.latest_version]
        unreviewed = versions |> Enum.reject(&RebarPlugins.reviewed?(package, &1)) |> Enum.uniq()
        write(package, Enum.sort(unreviewed), now)
      end
    end)

    watched = watched()

    if missing != [] do
      Logger.warning(
        "rebar3 plugin watch not marked fresh: the registry read lists none of " <>
          Enum.join(missing, ", ")
      )
    end

    if watched != %{} do
      Logger.warning(
        "rebar3 plugin releases not reviewed, builds that ran them are withheld: " <>
          Enum.map_join(watched, "; ", fn {p, vs} -> "#{p} #{Enum.join(vs, ", ")}" end)
      )
    end

    watched
  end

  defp write(package, [], _now),
    do: Portal.Repo.query!("DELETE FROM rebar3_plugin_watch WHERE package = $1", [package])

  defp write(package, unreviewed, now) do
    Portal.Repo.query!(
      "INSERT INTO rebar3_plugin_watch (package, unreviewed, checked_at) " <>
        "VALUES ($1, $2, $3) ON CONFLICT (package) DO UPDATE " <>
        "SET unreviewed = EXCLUDED.unreviewed, checked_at = EXCLUDED.checked_at",
      [package, unreviewed, now]
    )
  end

  @doc "The watch: `%{package => [version]}` of each package with releases outside the review."
  @spec watched() :: %{String.t() => [String.t()]}
  def watched do
    %{rows: rows} =
      Portal.Repo.query!(
        "SELECT package, unreviewed FROM rebar3_plugin_watch ORDER BY package",
        []
      )

    Map.new(rows, fn [package, versions] -> {package, versions} end)
  end

  @doc """
  A subquery of one row per catalog package with a plugin record,
  `package_id` and `watch`: the watch entries of the plugin packages its
  runs ran, as text, and whether the watch is stale, for the manifest
  fingerprints (`Portal.Catalog.precompiled_fingerprints/0`). A package
  without a record has no row, so its fingerprint is the same bytes
  whatever the watch holds (review S5 N8). Literal SQL only.
  """
  @spec fingerprint_sql() :: String.t()
  def fingerprint_sql do
    entry = "w.package || ':' || array_to_string(w.unreviewed, ',')"

    "SELECT bp.package_id, coalesce(string_agg(DISTINCT #{entry}, ';' ORDER BY #{entry}), '') " <>
      "|| CASE WHEN #{@stale_sql} THEN '|stale' ELSE '' END AS watch " <>
      "FROM rebar3_plugin_runs bp LEFT JOIN rebar3_plugin_watch w ON w.package = bp.package " <>
      "GROUP BY bp.package_id"
  end

  @doc "The ones of `run_ids` whose run ran a watched package."
  @spec withheld_runs([String.t() | nil]) :: MapSet.t()
  def withheld_runs(run_ids) do
    case Enum.filter(run_ids, &is_binary/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      ids ->
        %{rows: rows} = Portal.Repo.query!(@withheld_runs_sql, [ids])

        MapSet.new(rows, &hd/1)
    end
  end

  @doc """
  The SQL predicate that serves a build whose run id is the expression
  `run_id` only while its run ran no watched package and its record is not
  the withholding mark. Literal SQL only.
  """
  @spec served_clause(String.t()) :: String.t()
  def served_clause(run_id) do
    "NOT EXISTS (SELECT 1 FROM rebar3_plugin_runs bp " <>
      "WHERE bp.run_id = #{run_id} AND #{@withholds})"
  end

  @doc """
  The SQL condition, true while the watch is stale: no refresh in the last
  `max_age_hours/0` hours, or none ever. Literal SQL only.
  """
  @spec stale_sql() :: String.t()
  def stale_sql, do: @stale_sql

  @doc "Whether the watch is stale (`stale_sql/0`): every build that ran a plugin is withheld."
  @spec stale?() :: boolean()
  def stale? do
    %{rows: [[stale]]} = Portal.Repo.query!(@stale_query, [])
    stale
  end
end
