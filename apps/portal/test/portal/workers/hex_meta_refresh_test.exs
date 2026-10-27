defmodule Portal.Workers.HexMetaRefreshTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.Package
  alias Portal.Workers.{HexMetaRefresh, PackageMeta}

  defp seed(name) do
    {:ok, package} =
      Package
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(domain: Portal.Catalog)

    package
  end

  # Download counts go stale within weeks, so the refresh must reach packages
  # whose metadata was already fetched -- not just the never-fetched ones the
  # one-off backfill targets.
  test "every package is re-enqueued, already-fetched ones included" do
    seed("jason")

    seed("plug")
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_links: %{}, hex_owners: []})
    |> Ash.update!(domain: Portal.Catalog)

    assert :ok = perform_job(HexMetaRefresh, %{})

    names = all_enqueued(worker: PackageMeta) |> Enum.map(& &1.args["package"]) |> Enum.sort()
    assert names == ["jason", "plug"]
  end

  # ~2,500 requests at once would trip hex.pm's unauthenticated rate limit;
  # the refresh must spread them out, at least a second apart.
  test "the re-enqueued jobs are scheduled at distinct times, at least a second apart" do
    names = ["circuits_gpio", "jason", "plug", "vintage_net"]
    Enum.each(names, &seed/1)

    assert :ok = perform_job(HexMetaRefresh, %{})

    times =
      all_enqueued(worker: PackageMeta)
      |> Enum.map(& &1.scheduled_at)
      |> Enum.sort(DateTime)

    n = length(names)
    assert length(times) == n
    assert length(Enum.uniq(times)) == n
    assert DateTime.diff(List.last(times), List.first(times), :second) >= n - 1
  end
end
