defmodule Portal.Catalog.CoverageMetrics do
  @moduledoc """
  The two coverage numbers the precompiled work is measured by, per
  configured toolchain (`Portal.Toolchains.images/0`), over every package:

    * **download-weighted coverage**: the summed hex.pm recent downloads of
      the served packages over those of every counted package, the share of
      what people install that is served;
    * **coverage of the packages that compile**: served packages over the
      counted packages less the compile failures and the Gleam packages. A
      genuine compile failure fails the user's own compile too, so no build
      can serve it; and no Elixir before 1.22 compiles a Gleam dependency
      (Mix's `:gleam` manager, elixir-lang/elixir#14262), so a user has no
      own compile of one either. Both are counted apart (`compile_failures`,
      `gleam`); the download-weighted share keeps them.

  A package is counted at its newest stable release on Hex, a retired one
  included (`mix hex.retire`: it "is still resolvable and usable"), else its
  newest prerelease: what a fresh `mix deps.get` resolves. Not the catalog's
  `latest_version`, which is the highest version tested and can be a
  prerelease (postgrex 1.0.0-rc.1, while 0.22.4 is served).

  Counted are the catalog packages the registry lists, less the Nerves
  tooling (`Portal.Catalog.ToolingSkip`) and the packages with nothing to
  compile: no served build and a `"no compiled beams"` one, whose own
  compile only writes the `.app` file. Those are reported apart
  (`nothing_to_compile`).

  A package is served by a passing, unrevoked toolchain build of that
  version, of the default config and a `with` or `without` variant, as
  `Portal.Catalog.Coverage` counts one, a build whose closure is withheld
  included. It is a compile failure when nothing serves it and a toolchain
  build of the version failed to compile (`"compile failed: ..."`, but not
  one a signal killed, which is no verdict:
  `Portal.Catalog.killed_compile_sql/1`), or, with no toolchain build of the
  version at all, the host compile of its newest run failed. That fallback
  is the firmware project's compile, so it also counts a dependency
  resolution that failed against the Nerves project's own dependencies,
  which a plain Mix project would not hit (about 50 packages on
  2026-11-21), and a host compile a signal killed: both raise the second
  percentage a little.

  A package is Gleam when nothing serves it and a toolchain build of the
  version is skipped for a Gleam build tool, its own (`"Package uses gleam
  build tool"`) or a dependency's (`"dependency uses gleam build tool:
  ..."`), or, with no toolchain build of the version at all, a run of the
  package was skipped for its own Gleam build tool.

  Computing it reads the registry and runs one query per toolchain over the
  whole catalog, so the admin Maintenance page shows a stored copy
  (`store/1`, `latest/0`) that `Portal.Workers.CoverageRefresh` recomputes
  hourly.
  """

  require Ash.Query

  alias Portal.Catalog.{CoverageReport, ToolchainBuild, ToolingSkip}
  alias Portal.Repo

  @key "metrics"

  @type row :: %{
          toolchain: String.t(),
          packages: non_neg_integer(),
          downloads: non_neg_integer(),
          served: non_neg_integer(),
          served_downloads: non_neg_integer(),
          compile_failures: non_neg_integer(),
          compile_failure_downloads: non_neg_integer(),
          nothing_to_compile: non_neg_integer(),
          gleam: non_neg_integer(),
          download_percent: float(),
          compile_percent: float()
        }
  @type t :: %{toolchains: [row()]}

  @counts_sql """
  WITH latest AS (
    SELECT * FROM unnest($1::text[], $2::text[]) AS l(name, version)
  ), builds AS (
    SELECT p.id, coalesce(p.hex_downloads_recent, 0) AS downloads, l.version,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default' AND t.variant = ANY($4::text[])
          AND t.revoked_at IS NULL AND t.status = 'pass'
      ) AS served,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default' AND t.variant = ANY($4::text[])
          AND t.revoked_at IS NULL AND t.status = 'skipped'
          AND t.reason = 'no compiled beams'
      ) AS no_beams,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default' AND t.variant = ANY($4::text[])
          AND t.revoked_at IS NULL AND t.status = 'fail'
          AND t.reason LIKE 'compile failed: %' AND NOT $KILLED
      ) AS compile_failed,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default'
      ) AS built,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default' AND t.variant = ANY($4::text[])
          AND t.revoked_at IS NULL AND t.status = 'skipped'
          AND (t.reason LIKE 'Package uses gleam build tool%'
               OR t.reason LIKE 'dependency uses gleam build tool: %')
      ) AS gleam_build,
      (SELECT s.status
       FROM catalog_runs r
       JOIN catalog_system_results s ON s.run_id = r.id AND s.system_pkg = 'host'
       WHERE r.package_id = p.id AND r.version_tested = l.version AND r.revoked_at IS NULL
       ORDER BY r.finished_at DESC NULLS LAST
       LIMIT 1) AS host
    FROM catalog_packages p
    JOIN latest l ON l.name = p.name
  ), judged AS (
    -- The runs are read only for a package with no toolchain build of the
    -- version, a few thousand, not for every package.
    SELECT b.*,
      NOT b.served AND (b.gleam_build OR (NOT b.built AND EXISTS (
        SELECT 1 FROM catalog_runs r
        JOIN catalog_system_results s ON s.run_id = r.id
        WHERE r.package_id = b.id AND r.revoked_at IS NULL
          AND s.status = 'skipped' AND s.log_tail LIKE 'Package uses gleam build tool%'
      ))) AS gleam
    FROM builds b
    WHERE b.served OR NOT b.no_beams
  ), counted AS (
    SELECT *,
      NOT served AND NOT gleam
        AND (compile_failed OR (NOT built AND host IS NOT DISTINCT FROM 'fail')) AS failure
    FROM judged
  )
  SELECT count(*), coalesce(sum(downloads), 0),
    count(*) FILTER (WHERE served), coalesce(sum(downloads) FILTER (WHERE served), 0),
    count(*) FILTER (WHERE failure), coalesce(sum(downloads) FILTER (WHERE failure), 0),
    (SELECT count(*) FROM builds WHERE NOT served AND no_beams),
    count(*) FILTER (WHERE gleam)
  FROM counted
  """

  # At run time, so this module needs no compile-time dependency on the
  # catalog for the killed-compile clause.
  defp counts_sql,
    do: String.replace(@counts_sql, "$KILLED", Portal.Catalog.killed_compile_sql("t"))

  @doc """
  The metrics for `registry` (`Portal.HexRegistry.snapshot/1` with
  `all_versions: true`), toolchains in configured order.
  """
  @spec compute([map()]) :: t()
  def compute(registry) do
    {names, versions} =
      registry
      |> Enum.reject(&ToolingSkip.tooling?(&1.name))
      |> Enum.flat_map(fn entry ->
        case resolved(entry) do
          nil -> []
          version -> [{entry.name, version}]
        end
      end)
      |> Enum.unzip()

    variants = Enum.map(ToolchainBuild.optional_deps_variants(), &Atom.to_string/1)

    %{
      toolchains:
        for %{toolchain: toolchain} <- Portal.Toolchains.images() do
          row(toolchain, names, versions, variants)
        end
    }
  end

  # `counts_sql/0` is a module constant with a literal clause put in;
  # every value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp row(toolchain, names, versions, variants) do
    %{rows: [[packages, downloads, served, served_dl, failures, failure_dl, nothing, gleam]]} =
      Repo.query!(counts_sql(), [names, versions, toolchain, variants],
        timeout: :timer.minutes(5)
      )

    [downloads, served_dl, failure_dl] = Enum.map([downloads, served_dl, failure_dl], &integer/1)

    %{
      toolchain: toolchain,
      packages: packages,
      downloads: downloads,
      served: served,
      served_downloads: served_dl,
      compile_failures: failures,
      compile_failure_downloads: failure_dl,
      nothing_to_compile: nothing,
      gleam: gleam,
      download_percent: percent(served_dl, downloads),
      compile_percent: percent(served, packages - failures - gleam)
    }
  end

  # The newest stable release a fresh resolve takes, else the newest
  # prerelease; nil for an entry with no version that parses.
  defp resolved(entry) do
    parsed =
      for version <- Map.get(entry, :versions) || [entry.latest_version],
          {:ok, parsed} <- [Version.parse(version || "")],
          do: parsed

    case {Enum.filter(parsed, &(&1.pre == [])), parsed} do
      {[], []} -> nil
      {[], all} -> all |> Enum.max(Version) |> to_string()
      {stable, _} -> stable |> Enum.max(Version) |> to_string()
    end
  end

  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value) when is_integer(value), do: value

  defp percent(_part, 0), do: 0.0
  defp percent(part, whole), do: Float.round(part * 100 / whole, 1)

  @doc """
  Stores `metrics` as the latest (`Portal.Catalog.CoverageReport`, its own
  key beside `Portal.Catalog.Coverage`'s report), computed now.
  """
  @spec store(t()) :: {:ok, CoverageReport.t()} | {:error, term()}
  def store(metrics) do
    CoverageReport
    |> Ash.Changeset.for_create(:upsert, %{
      key: @key,
      report: metrics,
      computed_at: DateTime.utc_now()
    })
    |> Ash.create(domain: Portal.Catalog)
  end

  @doc """
  The latest stored metrics, in the shape `compute/1` returns, with the time
  they were computed; nil before the first refresh. Reads one row.
  """
  @spec latest() :: %{metrics: t(), computed_at: DateTime.t()} | nil
  def latest do
    CoverageReport
    |> Ash.Query.filter(key == @key)
    |> Ash.read_one!(domain: Portal.Catalog)
    |> case do
      nil -> nil
      stored -> %{metrics: from_stored(stored.report), computed_at: stored.computed_at}
    end
  end

  @fields ~w(toolchain packages downloads served served_downloads compile_failures
             compile_failure_downloads nothing_to_compile gleam download_percent
             compile_percent)a

  # The row holds the metrics as JSON, string keys; only the names
  # `compute/1` writes are read back.
  defp from_stored(stored) do
    %{
      toolchains:
        for row <- stored["toolchains"] || [] do
          Map.new(@fields, &{&1, Map.get(row, Atom.to_string(&1))})
          |> Map.update!(:download_percent, &as_float/1)
          |> Map.update!(:compile_percent, &as_float/1)
        end
    }
  end

  defp as_float(number) when is_number(number), do: number * 1.0
  defp as_float(_other), do: 0.0
end
