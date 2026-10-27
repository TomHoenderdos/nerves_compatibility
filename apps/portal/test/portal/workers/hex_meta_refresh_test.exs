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
end
