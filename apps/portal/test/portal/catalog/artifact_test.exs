defmodule Portal.Catalog.ArtifactTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{Artifact, ArtifactMembership, Package, Run, SystemResult}

  defp system_results(system_pkgs) do
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

    Enum.map(system_pkgs, fn system_pkg ->
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: system_pkg,
        status: :pass
      })
      |> Ash.create!(domain: Portal.Catalog)
    end)
  end

  defp create_artifact(sha, attrs \\ %{}) do
    Artifact
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{sha256: sha, byte_size: 42, disk_path: "/var/portal/artifacts/#{sha}"}, attrs)
    )
    |> Ash.create!(domain: Portal.Catalog)
  end

  defp create_membership(system_result_id, sha) do
    ArtifactMembership
    |> Ash.Changeset.for_create(:create, %{sha256: sha, system_result_id: system_result_id})
    |> Ash.create!(domain: Portal.Catalog)
  end

  describe "Artifact" do
    test "stores blob metadata and rejects a duplicate sha256" do
      artifact = create_artifact("abc123")

      assert artifact.sha256 == "abc123"

      # The registry is keyed by content, so one sha is one row forever. This is
      # correct for a blob store and was exactly wrong as a record of ownership.
      assert_raise Ash.Error.Invalid, fn ->
        create_artifact("abc123", %{byte_size: 99, disk_path: "/other/path"})
      end
    end
  end

  describe "ArtifactMembership" do
    test "one blob can belong to several system results" do
      # The regression this table exists for: two targets compile the same
      # source to byte-identical output, so both manifests must be able to
      # publish the one stored blob. Under the old single-table model the
      # second system silently recorded nothing.
      [rpi4, x86_64] = system_results(["nerves_system_rpi4", "nerves_system_x86_64"])
      sha = "shared00000000000000000000000000000000000000000000000000000001"

      create_artifact(sha)
      create_membership(rpi4.id, sha)
      create_membership(x86_64.id, sha)

      memberships = Ash.read!(ArtifactMembership, domain: Portal.Catalog)

      assert Enum.map(memberships, & &1.system_result_id) |> Enum.sort() ==
               Enum.sort([rpi4.id, x86_64.id])

      assert Enum.all?(memberships, &(&1.sha256 == sha))
      assert length(Ash.read!(Artifact, domain: Portal.Catalog)) == 1
    end

    test "rejects the same blob twice for one system result" do
      [rpi4] = system_results(["nerves_system_rpi4"])
      sha = "dupe000000000000000000000000000000000000000000000000000000000001"

      create_artifact(sha)
      create_membership(rpi4.id, sha)

      assert_raise Ash.Error.Invalid, fn -> create_membership(rpi4.id, sha) end
    end

    test "upsert makes a re-ingest of the same run a no-op" do
      [rpi4] = system_results(["nerves_system_rpi4"])
      sha = "upsert0000000000000000000000000000000000000000000000000000000001"

      create_artifact(sha)

      Enum.each(1..2, fn _ ->
        ArtifactMembership
        |> Ash.Changeset.for_create(:upsert, %{sha256: sha, system_result_id: rpi4.id})
        |> Ash.create!(domain: Portal.Catalog)
      end)

      assert length(Ash.read!(ArtifactMembership, domain: Portal.Catalog)) == 1
    end
  end
end
