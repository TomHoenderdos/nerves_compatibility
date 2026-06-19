defmodule Portal.Catalog.PackageOverrideTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.PackageOverride

  test "stores per-package override metadata" do
    override =
      PackageOverride
      |> Ash.Changeset.for_create(:create, %{
        package_name: "phoenix",
        forced_status: :pass,
        allow_systems: ["nerves_system_rpi4"],
        deny_systems: [],
        notes: "Manually approved by maintainer"
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert override.package_name == "phoenix"
    assert override.forced_status == :pass
    assert override.allow_systems == ["nerves_system_rpi4"]
  end

  test "rejects duplicate package_name" do
    PackageOverride
    |> Ash.Changeset.for_create(:create, %{package_name: "dup_override"})
    |> Ash.create!(domain: Portal.Catalog)

    assert_raise Ash.Error.Invalid, fn ->
      PackageOverride
      |> Ash.Changeset.for_create(:create, %{package_name: "dup_override"})
      |> Ash.create!(domain: Portal.Catalog)
    end
  end
end
