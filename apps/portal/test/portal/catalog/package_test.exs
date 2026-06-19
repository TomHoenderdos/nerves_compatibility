defmodule Portal.Catalog.PackageTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.Package

  test "creates and reads a package" do
    pkg =
      Package
      |> Ash.Changeset.for_create(:create, %{
        name: "jason",
        description: "JSON for Elixir",
        latest_version: "1.4.1"
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert pkg.name == "jason"
    assert pkg.latest_version == "1.4.1"

    [read_back] = Ash.read!(Package, domain: Portal.Catalog)
    assert read_back.id == pkg.id
  end

  test "rejects duplicate package names via the unique identity" do
    %{name: "dup_name"}
    |> create_package!()

    assert_raise Ash.Error.Invalid, fn ->
      Package
      |> Ash.Changeset.for_create(:create, %{name: "dup_name"})
      |> Ash.create!(domain: Portal.Catalog)
    end
  end

  test "upserts on name (insert then update in place)" do
    inserted =
      Package
      |> Ash.Changeset.for_create(:upsert, %{
        name: "upsert_pkg",
        description: "first",
        latest_version: "0.1.0"
      })
      |> Ash.create!(domain: Portal.Catalog)

    upserted =
      Package
      |> Ash.Changeset.for_create(:upsert, %{
        name: "upsert_pkg",
        description: "second",
        latest_version: "0.2.0"
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert upserted.id == inserted.id
    assert upserted.description == "second"
    assert upserted.latest_version == "0.2.0"

    assert [%Package{name: "upsert_pkg", latest_version: "0.2.0"}] =
             Ash.read!(Package, domain: Portal.Catalog)
  end

  defp create_package!(attrs) do
    Package
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(domain: Portal.Catalog)
  end
end
