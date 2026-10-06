defmodule Portal.Catalog.Browse do
  @moduledoc """
  One page of the `/packages` listing, read from Postgres.

  The listing used to be built from `Portal.Catalog.latest_by_pkg_json/0`: every
  package, its latest run and that run's system results, loaded through Ash and
  folded in Elixir, then mapped, filtered and sorted per mount, per keystroke
  and per "load more". On 2026-10-06 that was 22,141 packages, 23,344 runs and
  47,455 system results, and `GET /packages` took 1.9-8.7s in the server log,
  while the same reads in `psql` took 16ms (packages), 55ms (latest run per
  package) and 70ms (all system results). The time was in the application, so
  the fix is to stop moving the catalog into it: Postgres filters, sorts, counts
  and pages, and only the cards on the page are built here.

  The listing is the union of catalog packages and placeholders -- names with
  an open or failed scan request and no catalog row yet, so someone who asked
  for a package can find it before (or after a failed) first build.

  Entries are the card fields minus `href`: links are the web layer's to build.
  """

  import Ecto.Query

  alias Portal.Repo

  @placeholder_statuses ["accepted", "queued", "error"]

  @doc """
  The entries at `offset..offset + limit - 1` of the listing filtered by `q`,
  and the number of entries the filter matches.

  `q` is matched case-insensitively against a lowercase name, as a literal
  substring: `%`, `_` and `\\` in it match themselves.
  """
  @spec page(String.t(), non_neg_integer(), pos_integer()) :: {[map()], non_neg_integer()}
  def page(q, offset, limit) do
    listing = listing(pattern(q))

    rows =
      from(l in subquery(listing),
        # Byte order, which is what `Enum.sort_by(& &1.name)` gave the list
        # before it moved here. The database collation would interleave case
        # and punctuation differently and reorder existing pages.
        order_by: fragment("? COLLATE \"C\"", l.name),
        offset: ^offset,
        limit: ^limit
      )
      |> Repo.all()

    count = from(l in subquery(listing), select: count()) |> Repo.one!()

    {cards(rows), count}
  end

  # `LIKE '%term%'` rather than `strpos`: a trigram index can serve the former,
  # and on production `strpos` scanned the whole name index to answer a search
  # (10,888 heap fetches for "circ").
  defp pattern(q) do
    term = q |> to_string() |> String.downcase()
    escaped = String.replace(term, ["\\", "%", "_"], &("\\" <> &1))
    "%" <> escaped <> "%"
  end

  defp listing(pattern) do
    packages =
      from(p in "catalog_packages",
        where: like(p.name, ^pattern),
        select: %{
          name: p.name,
          package_id: type(p.id, Ecto.UUID),
          description: p.description,
          latest_version: p.latest_version,
          request_status: type(fragment("NULL"), :string)
        }
      )

    union_all(packages, ^placeholders(pattern))
  end

  # One row per name. An open request wins over a failed one for the same
  # package, because a rebuild is under way.
  #
  # `NOT EXISTS` rather than `name NOT IN (catalog names)`: the list form sent
  # all 22k catalog names as a parameter and cost 330ms per call on production.
  defp placeholders(pattern) do
    requests =
      from(r in "portal_scan_requests",
        as: :request,
        where: r.status in ^@placeholder_statuses,
        where: like(r.package_name, ^pattern),
        where:
          not exists(
            from(p in "catalog_packages",
              where: p.name == parent_as(:request).package_name,
              select: 1
            )
          ),
        distinct: r.package_name,
        order_by: [r.package_name, fragment("CASE WHEN ? = 'error' THEN 1 ELSE 0 END", r.status)],
        select: %{name: r.package_name, status: r.status}
      )

    from(r in subquery(requests),
      select: %{
        name: r.name,
        package_id: type(fragment("NULL"), Ecto.UUID),
        description: type(fragment("NULL"), :string),
        latest_version: type(fragment("NULL"), :string),
        request_status: r.status
      }
    )
  end

  defp cards(rows) do
    statuses = statuses_by_package(for %{package_id: id} <- rows, id, do: id)
    Enum.map(rows, &card(&1, statuses))
  end

  defp card(%{request_status: "error", name: name}, _statuses) do
    placeholder(name, "First scan failed.", "build failed", "error")
  end

  defp card(%{request_status: status, name: name}, _statuses) when is_binary(status) do
    placeholder(name, "Awaiting first scan.", "in queue", "queued")
  end

  defp card(row, statuses) do
    statuses = Map.get(statuses, row.package_id, [])
    {summary, summary_status} = summarize(statuses)

    %{
      name: row.name,
      description: row.description,
      version: row.latest_version && "v#{row.latest_version}",
      summary: summary,
      summary_status: summary_status,
      statuses: statuses,
      placeholder?: false
    }
  end

  defp placeholder(name, description, summary, summary_status) do
    %{
      name: name,
      description: description,
      version: nil,
      summary: summary,
      summary_status: summary_status,
      statuses: [],
      placeholder?: true
    }
  end

  # The system statuses of each package's latest run, for the packages on the
  # page only. Same latest-run rule as `Portal.Catalog`: newest `finished_at`,
  # then newest `inserted_at`; plain `DESC`, so an unfinished run sorts first
  # there too.
  defp statuses_by_package([]), do: %{}

  defp statuses_by_package(package_ids) do
    latest =
      from(r in "catalog_runs",
        where: r.package_id in type(^package_ids, {:array, Ecto.UUID}),
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{id: r.id, package_id: r.package_id}
      )

    from(s in "catalog_system_results",
      join: r in subquery(latest),
      on: r.id == s.run_id,
      select: {type(r.package_id, Ecto.UUID), s.system_pkg, s.system_version, s.status}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, pkg, version, status} ->
      {"#{pkg}@#{version}", status}
    end)
    # Keyed by system the way `latest_by_pkg_json/0` keys `systems`, so the dots
    # come out in the order and number they did when the card was built from it.
    |> Map.new(fn {id, systems} -> {id, systems |> Map.new() |> Map.values()} end)
  end

  defp summarize(statuses) do
    cond do
      statuses == [] -> {"not run", "skipped"}
      "error" in statuses -> {tally(statuses), "error"}
      "fail" in statuses -> {tally(statuses), "fail"}
      Enum.all?(statuses, &(&1 == "pass")) -> {tally(statuses), "pass"}
      true -> {tally(statuses), "skipped"}
    end
  end

  defp tally(statuses) do
    pass = Enum.count(statuses, &(&1 == "pass"))
    "#{pass}/#{length(statuses)} pass"
  end
end
