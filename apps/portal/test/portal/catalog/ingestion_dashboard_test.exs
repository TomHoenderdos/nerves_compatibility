defmodule Portal.Catalog.IngestionDashboardTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  @result %{
    "package" => %{
      "name" => "dashpkg",
      "version" => "0.1.0",
      "description" => "x",
      "native_components" => %{"nif_language" => "rust", "build_tool" => "rustler"}
    },
    "finished_at" => "2026-07-01T10:00:00Z",
    "systems" => %{
      "nerves_system_rpi0" => %{
        "status" => "fail",
        "log_tail" => "sh: cannot execute binary file: Exec format error",
        "system_version" => "1.24.0",
        "firmware_size_bytes" => nil,
        "beam_scan" => nil,
        "dependency_scans" => nil,
        "error" => nil
      }
    }
  }

  defp files_dir do
    dir = Path.join(System.tmp_dir!(), "ingest-dashboard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "ingestion stores log_tail, failure_category, and native_components" do
    {:ok, _run} =
      Ingestion.ingest(@result, %{
        run_id: "dashpkg-1",
        image_digest: "sha256:x",
        files_dir: files_dir(),
        scan_request_id: nil,
        log: "log"
      })

    [sr] = Catalog.latest_system_results("dashpkg")
    assert sr.status == :fail
    assert sr.log_tail =~ "Exec format error"
    assert sr.failure_category == "NIF built for wrong architecture"

    %{packages: %{"dashpkg" => pkg}} = Catalog.latest_by_pkg_json("dashpkg")
    assert %{"nif_language" => "rust", "build_tool" => "rustler"} = pkg.native_components
  end
end
