defmodule Portal.Catalog.HotTickets do
  @moduledoc """
  Packages whose latest run fails, ranked by hex.pm downloads: the failures
  worth fixing first. Backs `/failing` and `GET /api/failing`.

  "Latest run" is the rule `Portal.Catalog.latest_results/0` applies -- newest
  `finished_at`, then newest `inserted_at`, plain `DESC`, no `revoked_at`
  filter -- so this list never disagrees with `/packages/<name>`. A package is
  listed when any target of that run is `:fail` or `:error`.

  Two queries: the ranked, limited packages, then the failing targets of just
  those runs.
  """

  import Ecto.Query

  alias Portal.Repo

  @failing ["fail", "error"]
  @default_limit 50
  @max_limit 200

  @type row :: %{
          name: String.t(),
          description: String.t() | nil,
          latest_version: String.t() | nil,
          version_tested: String.t() | nil,
          last_run_at: DateTime.t() | nil,
          downloads_recent: non_neg_integer() | nil,
          downloads_all: non_neg_integer() | nil,
          status: :fail | :error,
          failing_targets: [
            %{system: String.t(), status: :fail | :error, failure_category: String.t() | nil}
          ],
          failing_count: pos_integer(),
          total_targets: pos_integer()
        }

  @doc """
  Options:

    * `:limit` - rows to return, clamped to `1..#{@max_limit}` (default `#{@default_limit}`)
    * `:sort` - `:recent` (hex.pm 90-day downloads, default) or `:all`
    * `:system` - a system package name, e.g. `"nerves_system_rpi4"`; only
      packages failing on that target

  Ordered by the chosen download count, highest first, packages without one
  last, then by name.
  """
  @spec list(keyword()) :: [row()]
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    sort = Keyword.get(opts, :sort, :recent)
    system = Keyword.get(opts, :system)

    packages = sort |> packages_query(system, limit) |> Repo.all()
    targets = failing_targets(Enum.map(packages, & &1.run_id))

    Enum.map(packages, fn package ->
      failing = Map.get(targets, package.run_id, [])

      package
      |> Map.delete(:run_id)
      |> Map.merge(%{
        status: if(Enum.any?(failing, &(&1.status == :error)), do: :error, else: :fail),
        failing_targets: failing
      })
    end)
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_limit), do: @default_limit

  defp packages_query(sort, system, limit) do
    downloads_field = if sort == :all, do: :hex_downloads_all, else: :hex_downloads_recent

    from([s, r] in latest_results(),
      join: p in "catalog_packages",
      on: p.id == r.package_id,
      group_by: [p.id, r.id, r.version_tested, r.finished_at],
      having: fragment("bool_or(? = ANY(?))", s.status, ^@failing),
      order_by: [
        desc_nulls_last: field(p, ^downloads_field),
        asc: p.name
      ],
      limit: ^limit,
      select: %{
        run_id: r.id,
        name: p.name,
        description: p.description,
        latest_version: p.latest_version,
        version_tested: r.version_tested,
        last_run_at: type(r.finished_at, :utc_datetime_usec),
        downloads_recent: p.hex_downloads_recent,
        downloads_all: p.hex_downloads_all,
        failing_count: filter(count(s.id), s.status in ^@failing),
        total_targets: count(s.id)
      }
    )
    |> filter_system(system)
  end

  defp filter_system(query, system) when is_binary(system) and system != "" do
    having(
      query,
      [s],
      fragment("bool_or(? = ? AND ? = ANY(?))", s.system_pkg, ^system, s.status, ^@failing)
    )
  end

  defp filter_system(query, _system), do: query

  defp failing_targets([]), do: %{}

  defp failing_targets(run_ids) do
    from(s in "catalog_system_results",
      where: s.run_id in ^run_ids and s.status in ^@failing,
      order_by: [asc: s.system_pkg, asc: s.system_version],
      select: {s.run_id, s.system_pkg, s.system_version, s.status, s.failure_category}
    )
    |> Repo.all()
    |> Enum.group_by(
      &elem(&1, 0),
      fn {_run_id, pkg, version, status, category} ->
        %{system: "#{pkg}@#{version}", status: status_atom(status), failure_category: category}
      end
    )
  end

  defp status_atom("fail"), do: :fail
  defp status_atom("error"), do: :error

  # Mirrors `Portal.Catalog.latest_results/0` (private there); keep the two in
  # step or `/failing` and `/packages/<name>` disagree about a package's latest
  # run.
  defp latest_results do
    latest =
      from(r in "catalog_runs",
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{
          id: r.id,
          package_id: r.package_id,
          version_tested: r.version_tested,
          finished_at: r.finished_at
        }
      )

    from(s in "catalog_system_results", join: r in subquery(latest), on: r.id == s.run_id)
  end
end
