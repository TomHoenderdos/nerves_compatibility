defmodule Portal.Catalog.ArtifactTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{Package, Run, SystemResult, Artifact}

  test "stores artifact metadata and rejects duplicate sha256" do
    package =
      Package
      |> Ash.Changeset.for_create(:create, %{name: "art_pkg"})
      |> Ash.create!(domain: Portal.Catalog)

    run =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "art-run",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:d",
        overall_status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)

    sr =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: "nerves_system_rpi4",
        status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)

    artifact =
      Artifact
      |> Ash.Changeset.for_create(:create, %{
        sha256: "abc123",
        byte_size: 42,
        disk_path: "/var/portal/artifacts/ab/abc123.bin",
        system_result_id: sr.id
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert artifact.sha256 == "abc123"

    assert_raise Ash.Error.Invalid, fn ->
      Artifact
      |> Ash.Changeset.for_create(:create, %{
        sha256: "abc123",
        byte_size: 99,
        disk_path: "/other/path",
        system_result_id: sr.id
      })
      |> Ash.create!(domain: Portal.Catalog)
    end
  end
end
