defmodule Portal.Catalog.CoverageMetrics do
  @moduledoc """
  The two coverage numbers the precompiled work is measured by, per
  configured toolchain (`Portal.Toolchains.images/0`), over every package:

    * **download-weighted coverage**: the summed hex.pm recent downloads of
      the served packages over those of every counted package, the share of
      what people install that is served;
    * **coverage of the packages that compile**: served packages over the
      counted packages less the compile failures. A genuine compile failure
      fails the user's own compile too, so no build can serve it.

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
  `Portal.Catalog.Coverage` counts one. It is a compile failure when nothing
  serves it and a toolchain build of the version failed to compile
  (`"compile failed: ..."`), or, with no toolchain build of the version at
  all, the host compile of its newest run failed.

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
          AND t.reason LIKE 'compile failed: %'
      ) AS compile_failed,
      EXISTS (
        SELECT 1 FROM catalog_toolchain_builds t
        WHERE t.package_id = p.id AND t.version = l.version AND t.toolchain = $3
          AND t.config_variant = 'default'
      ) AS built,
      (SELECT s.status
       FROM catalog_runs r
       JOIN catalog_system_results s ON s.run_id = r.id AND s.system_pkg = 'host'
       WHERE r.package_id = p.id AND r.version_tested = l.version AND r.revoked_at IS NULL
       ORDER BY r.finished_at DESC NULLS LAST
       LIMIT 1) AS host
    FROM catalog_packages p
    JOIN latest l ON l.name = p.name
  ), counted AS (
    SELECT *,
      NOT served AND (compile_failed OR (NOT built AND host IS NOT DISTINCT FROM 'fail'))
        AS failure
    FROM builds
    WHERE served OR NOT no_beams
  )
  SELECT count(*), coalesce(sum(downloads), 0),
    count(*) FILTER (WHERE served), coalesce(sum(downloads) FILTER (WHERE served), 0),
    count(*) FILTER (WHERE failure), coalesce(sum(downloads) FILTER (WHERE failure), 0),
    (SELECT count(*) FROM builds WHERE NOT served AND no_beams)
  FROM counted
  """

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

  defp row(toolchain, names, versions, variants) do
    %{rows: [[packages, downloads, served, served_dl, failures, failure_dl, nothing]]} =
      Repo.query!(@counts_sql, [names, versions, toolchain, variants], timeout: :timer.minutes(5))

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
      download_percent: percent(served_dl, downloads),
      compile_percent: percent(served, packages - failures)
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
             compile_failure_downloads nothing_to_compile download_percent compile_percent)a

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
