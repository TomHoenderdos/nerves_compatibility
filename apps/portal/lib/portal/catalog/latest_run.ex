defmodule Portal.Catalog.LatestRun do
  @moduledoc """
  The one rule for a package's latest version and its latest run, which the
  package page, the badge, the schema-v2 API, `/packages`, the dashboard and
  every job that keys on "the latest run" read.

  ## Latest version

  `Package.latest_version` is the highest version the package has a run of,
  by Hex's precedence (`compare/2`): `Version.compare/2`, so a pre-release
  counts and sorts below its own release, as Hex's own `latest_version` and
  the registry's version order (`Portal.HexRegistry`, which
  `Portal.Workers.UpdateCheck` compares against) do. Hex only publishes
  versions that parse; one that does not has no place in the order, and
  supersedes or is superseded by any other, as every run did before.

  Ingest (`Portal.Catalog.Ingestion`) only ever moves it up: a run of an
  older release (a forced build, a lock-driven build, a drift rebuild) is
  kept and served for its own version, by the precompiled API among others,
  and leaves the package row as it was: `latest_version`, `description`,
  `native_components` and `last_run_at` describe the latest version. A
  latest version with no run (`Ingestion.ingest_toolchain/2` creates a
  package it has not seen that way) is taken over by the first run of any
  version.

  ## Latest run

  The package's newest run of its latest version: newest `finished_at`, then
  newest `inserted_at`, plain `DESC` (Postgres's NULLS FIRST, so an
  unfinished run sorts first). A package with no run of its latest version,
  which ingest never leaves behind, falls back to its newest run of any
  version rather than to none. `query/0` is the rule for Ecto, `sql/1` for
  raw SQL and `pick/2` for runs already read newest first.
  """

  import Ecto.Query, only: [from: 2]

  @typedoc "How two versions order: `:unordered` when neither parses."
  @type order :: :gt | :eq | :lt | :unordered

  @doc """
  How `a` orders against `b` by Hex's precedence: `:unordered` when either
  does not parse and the two differ.
  """
  @spec compare(String.t(), String.t()) :: order()
  def compare(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb)
      _ when a == b -> :eq
      _ -> :unordered
    end
  end

  @doc """
  Whether a run of `version` makes it the package's latest version over
  `current`: it is no lower than `current`, or there is no `current`. A
  rebuild of the latest version itself does, so its run becomes the latest.
  """
  @spec supersedes?(String.t(), String.t() | nil) :: boolean()
  def supersedes?(_version, nil), do: true
  def supersedes?(version, current), do: compare(version, current) != :lt

  @doc """
  Whether `candidate` is a strictly newer release than `current`, the latest
  version on record (nil: none). Two versions out of order (`compare/2`)
  count as newer: rebuilding is the safe direction, and the run that comes
  back supersedes `current`.
  """
  @spec newer?(String.t(), String.t() | nil) :: boolean()
  def newer?(_candidate, nil), do: true
  def newer?(candidate, current), do: compare(candidate, current) in [:gt, :unordered]

  @doc """
  Each package's latest run, as an Ecto query on `catalog_runs` (first
  binding) joined to its package (second binding). Add `where` and `select`:

      from([r, p] in LatestRun.query(), where: p.name == ^name, select: r.id)

  `DISTINCT ON (package_id)`, so one row per package.
  """
  @spec query() :: Ecto.Query.t()
  def query do
    from(r in "catalog_runs",
      join: p in "catalog_packages",
      on: p.id == r.package_id,
      distinct: r.package_id,
      order_by: [
        asc: r.package_id,
        desc: fragment("? IS NOT DISTINCT FROM ?", r.version_tested, p.latest_version),
        desc: r.finished_at,
        desc: r.inserted_at
      ]
    )
  end

  @doc """
  The newest run of one version of a package, as an Ecto query on
  `catalog_runs` (first binding) joined to its package (second binding):
  the run a partial run of that version carries from, and what
  `Portal.Workers.Build.scope_args/3` needs to exist before it builds one.
  Of the latest version, it is the latest run.
  """
  @spec of_version(String.t(), String.t()) :: Ecto.Query.t()
  def of_version(package_name, version) do
    from(r in "catalog_runs",
      join: p in "catalog_packages",
      on: p.id == r.package_id,
      where: p.name == ^package_name and r.version_tested == ^version,
      order_by: [desc: r.finished_at, desc: r.inserted_at],
      limit: 1
    )
  end

  @doc """
  Each package's latest run in raw SQL: a `SELECT` of `columns` (over
  `catalog_runs r` and `catalog_packages p`), for a CTE or subquery.
  """
  @spec sql(String.t()) :: String.t()
  def sql(columns) do
    """
    SELECT DISTINCT ON (r.package_id) #{columns}
    FROM catalog_runs r
    JOIN catalog_packages p ON p.id = r.package_id
    ORDER BY r.package_id, r.version_tested IS NOT DISTINCT FROM p.latest_version DESC,
             r.finished_at DESC, r.inserted_at DESC
    """
  end

  @doc """
  Each package's latest run, `%{package_id => run}`, from `runs` read newest
  first (`finished_at: :desc, inserted_at: :desc`), given each package's
  latest version as `%{package_id => latest_version}`.
  """
  @spec pick([map()], %{optional(term()) => String.t() | nil}) :: %{optional(term()) => map()}
  def pick(runs, latest_versions) do
    Enum.reduce(runs, %{}, fn %{package_id: id} = run, acc ->
      latest = Map.get(latest_versions, id)

      case acc do
        %{^id => %{version_tested: ^latest}} -> acc
        %{^id => _} when run.version_tested == latest -> Map.put(acc, id, run)
        %{^id => _} -> acc
        _ -> Map.put(acc, id, run)
      end
    end)
  end
end
