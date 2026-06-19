defmodule Portal.Catalog.SystemResultTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{Package, Run, SystemResult}

  setup do
    package =
      Package
      |> Ash.Changeset.for_create(:create, %{name: "sr_pkg", latest_version: "1.0.0"})
      |> Ash.create!(domain: Portal.Catalog)

    run =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "run-1",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:deadbeef",
        overall_status: :pass,
        footprint: %{"firmware_bytes" => 12_345}
      })
      |> Ash.create!(domain: Portal.Catalog)

    {:ok, package: package, run: run}
  end

  for status <- [:pass, :fail, :error, :skipped, :unknown] do
    @status status

    test "round-trips Compatibility.Types status #{inspect(status)}", %{run: run} do
      sr =
        SystemResult
        |> Ash.Changeset.for_create(:create, %{
          run_id: run.id,
          system_pkg: "nerves_system_rpi4",
          system_version: "1.32.0",
          status: @status,
          firmware_size_bytes: 1000,
          hex_version_tested: "0.1.0",
          beam_scan: %{"nifs" => []},
          dependency_scans: %{"jason" => "ok"}
        })
        |> Ash.create!(domain: Portal.Catalog)

      assert sr.status == @status
      assert sr.status in [:pass, :fail, :error, :skipped, :unknown]
      # cross-check with shared Compatibility.Types contract
      assert Compatibility.Types.status_to_string(sr.status) ==
               to_string(@status)

      [reread] =
        Ash.read!(SystemResult, domain: Portal.Catalog)
        |> Enum.filter(&(&1.id == sr.id))

      assert reread.status == @status
    end
  end

  test "rejects a status atom outside the Compatibility.Types enum", %{run: run} do
    assert_raise Ash.Error.Invalid, fn ->
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: "nerves_system_rpi4",
        status: :pending
      })
      |> Ash.create!(domain: Portal.Catalog)
    end
  end
end
