defmodule Portal.Catalog.SchemaFieldsTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Package, Run, SystemResult}

  test "SystemResult persists failure_category and log_tail; Package persists native_components" do
    {:ok, pkg} =
      Package
      |> Ash.Changeset.for_create(:create, %{
        name: "schematest",
        native_components: %{"nif_language" => "rust", "port_languages" => []}
      })
      |> Ash.create(domain: Catalog)

    assert pkg.native_components == %{"nif_language" => "rust", "port_languages" => []}

    {:ok, run} =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "schematest-1",
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
        log_tail: "cannot execute binary file",
        failure_category: "NIF built for wrong architecture"
      })
      |> Ash.create(domain: Catalog)

    assert sr.failure_category == "NIF built for wrong architecture"
    assert sr.log_tail == "cannot execute binary file"
  end
end
