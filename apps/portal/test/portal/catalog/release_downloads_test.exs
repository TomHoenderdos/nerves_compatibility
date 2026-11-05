defmodule Portal.Catalog.ReleaseDownloadsTest do
  use Portal.DataCase, async: true

  require Ash.Query

  alias Portal.Catalog.ReleaseDownloads

  defp upsert(attrs) do
    ReleaseDownloads
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(domain: Portal.Catalog)
  end

  defp rows(package) do
    ReleaseDownloads
    |> Ash.Query.filter(package == ^package)
    |> Ash.read!(domain: Portal.Catalog)
  end

  test "a fetched count is stored per package version" do
    fetched_at = ~U[2026-11-02 04:00:00.000000Z]

    assert {:ok, row} =
             upsert(%{package: "jason", version: "1.4.5", downloads: 120, fetched_at: fetched_at})

    assert %{package: "jason", version: "1.4.5", downloads: 120} = row
    assert DateTime.compare(row.fetched_at, fetched_at) == :eq
  end

  # The weekly refresh writes the same versions again: one row each, holding
  # the newest count and when it was fetched.
  test "fetching a version again replaces its count, not adds a row" do
    {:ok, first} =
      upsert(%{
        package: "jason",
        version: "1.4.5",
        downloads: 120,
        fetched_at: ~U[2026-11-02 04:00:00Z]
      })

    {:ok, second} =
      upsert(%{
        package: "jason",
        version: "1.4.5",
        downloads: 180,
        fetched_at: ~U[2026-11-09 04:00:00Z]
      })

    assert first.id == second.id
    assert [%{downloads: 180} = row] = rows("jason")
    assert DateTime.compare(row.fetched_at, ~U[2026-11-09 04:00:00Z]) == :eq
  end

  test "versions of one package and the same version of two packages are separate rows" do
    for {package, version} <- [{"jason", "1.4.5"}, {"jason", "1.4.4"}, {"decimal", "1.4.5"}] do
      {:ok, _} =
        upsert(%{
          package: package,
          version: version,
          downloads: 1,
          fetched_at: DateTime.utc_now()
        })
    end

    assert length(rows("jason")) == 2
    assert length(rows("decimal")) == 1
  end

  # hex.pm answered without a usable count: the version was fetched, its
  # demand is unknown and sorts last.
  test "an unknown count is stored as nil" do
    assert {:ok, %{downloads: nil}} =
             upsert(%{
               package: "jason",
               version: "1.4.5",
               downloads: nil,
               fetched_at: DateTime.utc_now()
             })
  end

  test "a negative count is refused" do
    assert {:error, _} =
             upsert(%{
               package: "jason",
               version: "1.4.5",
               downloads: -1,
               fetched_at: DateTime.utc_now()
             })

    assert rows("jason") == []
  end

  test "package and version are required" do
    assert {:error, _} = upsert(%{version: "1.4.5", downloads: 1, fetched_at: DateTime.utc_now()})
    assert {:error, _} = upsert(%{package: "jason", downloads: 1, fetched_at: DateTime.utc_now()})
  end
end
