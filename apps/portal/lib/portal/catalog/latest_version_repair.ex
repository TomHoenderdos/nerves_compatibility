defmodule Portal.Catalog.LatestVersionRepair do
  @moduledoc """
  Counts, then repairs, the packages whose `latest_version` a build of an
  older release set back, before ingest only moved it up
  (`Portal.Catalog.LatestRun`). Such a package shows the older release on its
  page, its badge and the API, and `Portal.Workers.UpdateCheck` sees it as
  behind Hex. Nothing runs this on its own: no job and no schedule calls it.

  ## What is repaired

  A package is a candidate when it has a run of a version strictly higher,
  by Hex's precedence (`LatestRun.compare/2`), than its `latest_version`.
  The repair sets `latest_version` to the highest such version and
  `last_run_at` to the `finished_at` of that version's newest run, which is
  then the package's latest run again. No run is touched: the older
  release's runs stay, served for their own version.

  `description` and `native_components` stay as the older release's build
  wrote them: a run does not record them, and the next build of the latest
  version writes them again.

  ## Safety

    * `repair/1` counts unless given `dry_run: false`;
    * one call repairs at most `limit:` packages (default 50), by name;
    * each package is one `UPDATE` that re-checks the row still holds the
      `latest_version` and `last_run_at` it read, so an ingest in between
      wins and the package is left as that ingest wrote it;
    * it is idempotent: a repaired package is no longer a candidate;
    * the result lists every change (`from`, `to` and both `last_run_at`
      values), and `undo/1` given that list sets back each package that
      still holds what the repair wrote. The list is logged as well.

  Run it only once every host that runs `Portal.Workers.Ingest` runs a
  release with `LatestRun`: an older release's ingest would set a repaired
  package back again on the next old-version build.

  ## Operator commands (web host, through ops/portal-rpc.sh)

      Portal.Catalog.LatestVersionRepair.repair()
      Portal.Catalog.LatestVersionRepair.repair(dry_run: false)
      Portal.Catalog.LatestVersionRepair.undo(changes)

  The first lists every candidate; `changes` is the list the second
  returned. Repeat the second until it returns `{:repaired, []}`.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Portal.Catalog.LatestRun
  alias Portal.Repo

  @default_limit 50

  @typedoc "One package's change, as `repair/1` returns it and `undo/1` takes it."
  @type change :: %{
          name: String.t(),
          from: String.t() | nil,
          to: String.t(),
          from_last_run_at: DateTime.t() | nil,
          to_last_run_at: DateTime.t() | nil
        }

  # Each package with a run of a version other than its latest, and those
  # versions with the newest `finished_at` of each (`LatestRun.of_version/2`'s
  # order: plain DESC, so an unfinished run's NULL comes first).
  @candidates_sql """
  SELECT p.id, p.name, p.latest_version, p.last_run_at, v.version_tested, v.finished_at
  FROM catalog_packages p
  JOIN LATERAL (
    SELECT DISTINCT ON (r.version_tested) r.version_tested, r.finished_at
    FROM catalog_runs r
    WHERE r.package_id = p.id AND r.version_tested IS DISTINCT FROM p.latest_version
    ORDER BY r.version_tested, r.finished_at DESC, r.inserted_at DESC
  ) v ON true
  ORDER BY p.name
  """

  @doc """
  The packages behind their highest version, as `{:dry_run, changes}`, or
  with `dry_run: false` the ones repaired, as `{:repaired, changes}`, by
  name. Options: `dry_run:` (`true`), `limit:` (#{@default_limit}).
  """
  @spec repair(keyword()) :: {:dry_run, [change()]} | {:repaired, [change()]}
  def repair(opts \\ []) do
    changes = candidates()

    if Keyword.get(opts, :dry_run, true) do
      {:dry_run, changes}
    else
      repaired =
        changes
        |> Enum.take(Keyword.get(opts, :limit, @default_limit))
        |> Enum.filter(&write(&1, &1.from, &1.from_last_run_at, &1.to, &1.to_last_run_at))

      Logger.info("Latest version repair: #{inspect(repaired, limit: :infinity)}")
      {:repaired, repaired}
    end
  end

  @doc """
  Sets back each package of `changes` (a `repair/1` result's list) that
  still holds the `latest_version` and `last_run_at` the repair wrote.
  Returns `{:undone, count}`.
  """
  @spec undo([change()]) :: {:undone, non_neg_integer()}
  def undo(changes) when is_list(changes) do
    undone =
      Enum.count(changes, &write(&1, &1.to, &1.to_last_run_at, &1.from, &1.from_last_run_at))

    Logger.info("Latest version repair undone for #{undone} of #{length(changes)} packages")
    {:undone, undone}
  end

  defp candidates do
    %{rows: rows} = Repo.query!(@candidates_sql, [])

    rows
    |> Enum.chunk_by(&hd/1)
    |> Enum.flat_map(fn [[_id, name, latest, last_run_at | _] | _] = group ->
      versions =
        Enum.map(group, fn [_, _, _, _, version, finished_at] -> {version, finished_at} end)

      case highest(versions) do
        {version, finished_at} when is_nil(latest) ->
          [change(name, latest, last_run_at, version, finished_at)]

        {version, finished_at} ->
          if LatestRun.compare(version, latest) == :gt,
            do: [change(name, latest, last_run_at, version, finished_at)],
            else: []

        nil ->
          []
      end
    end)
  end

  # The highest version that parses; one that does not has no place in the
  # order to repair to.
  defp highest(versions) do
    versions
    |> Enum.filter(fn {version, _} -> match?({:ok, _}, Version.parse(version)) end)
    |> Enum.max(fn {a, _}, {b, _} -> LatestRun.compare(a, b) != :lt end, fn -> nil end)
  end

  defp change(name, from, from_last_run_at, to, finished_at) do
    %{
      name: name,
      from: from,
      to: to,
      from_last_run_at: utc(from_last_run_at),
      # `last_run_at` holds whole seconds, as ingest writes it.
      to_last_run_at: finished_at |> utc() |> truncate()
    }
  end

  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp truncate(nil), do: nil
  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)

  # One conditional statement: the row is written only while it still holds
  # `{version, last_run_at}`.
  defp write(%{name: name}, version, last_run_at, new_version, new_last_run_at) do
    {count, _} =
      Repo.update_all(
        from(p in "catalog_packages",
          where:
            p.name == ^name and
              fragment("? IS NOT DISTINCT FROM ?", p.latest_version, type(^version, :string)) and
              fragment(
                "? IS NOT DISTINCT FROM ?",
                p.last_run_at,
                type(^naive(last_run_at), :naive_datetime_usec)
              )
        ),
        set: [
          latest_version: new_version,
          last_run_at: naive(new_last_run_at),
          updated_at: NaiveDateTime.utc_now(:second)
        ]
      )

    count == 1
  end

  defp naive(nil), do: nil
  defp naive(%DateTime{} = at), do: DateTime.to_naive(at)
end
