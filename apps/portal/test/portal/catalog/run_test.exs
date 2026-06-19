defmodule Portal.Catalog.RunTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{Package, Run}
  alias Portal.ScanRequests.ScanRequest

  test "creates a run linked to a package and an optional scan_request" do
    package =
      Package
      |> Ash.Changeset.for_create(:create, %{name: "run_pkg"})
      |> Ash.create!(domain: Portal.Catalog)

    request =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: "run_pkg",
        source: :hex_owner,
        status: :accepted
      })
      |> Ash.create!(domain: Portal.ScanRequests)

    run =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "rid-1",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:1",
        overall_status: :pass,
        scan_request_id: request.id
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert run.package_id == package.id
    assert run.scan_request_id == request.id
    assert run.overall_status == :pass
  end

  test "scan_request_id is optional" do
    package =
      Package
      |> Ash.Changeset.for_create(:create, %{name: "run_pkg2"})
      |> Ash.create!(domain: Portal.Catalog)

    run =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "rid-2",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:2",
        overall_status: :fail
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert is_nil(run.scan_request_id)
  end
end
