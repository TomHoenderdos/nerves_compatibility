defmodule Mix.Tasks.Portal.ReclassifyTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Package, Run, SystemResult}

  test "reclassify sets failure_category from stored log_tail" do
    {:ok, pkg} =
      Package |> Ash.Changeset.for_create(:create, %{name: "recl"}) |> Ash.create(domain: Catalog)

    {:ok, run} =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "recl-1",
        package_id: pkg.id,
        version_tested: "1.0.0",
        image_digest: "sha256:x",
        overall_status: :fail
      })
      |> Ash.create(domain: Catalog)

    {:ok, sr} =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: "nerves_system_rpi0",
        status: :fail,
        log_tail: "Exec format error",
        failure_category: nil
      })
      |> Ash.create(domain: Catalog)

    assert sr.failure_category == nil

    Mix.Tasks.Portal.Reclassify.run([])

    updated = SystemResult |> Ash.get!(sr.id, domain: Catalog)
    assert updated.failure_category == "NIF built for wrong architecture"
  end
end
