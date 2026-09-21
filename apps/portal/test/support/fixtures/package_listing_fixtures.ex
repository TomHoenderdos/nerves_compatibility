defmodule Portal.PackageListingFixtures do
  @moduledoc false

  def request_fixture(name, attrs \\ %{}) do
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at, DateTime.utc_now())

    Portal.ScanRequests.ScanRequest
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{package_name: name, source: :anonymous_manual, status: :accepted}, attrs)
    )
    |> Ash.Changeset.force_change_attribute(:inserted_at, inserted_at)
    |> Ash.create!(domain: Portal.ScanRequests)
  end

  def package_fixture(name) do
    Portal.Catalog.Package
    |> Ash.Changeset.for_create(:create, %{name: name, latest_version: "1.0.0"})
    |> Ash.create!(domain: Portal.Catalog)
  end
end
