defmodule Portal.Catalog.Phase1aQueriesTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, version, systems, native \\ nil) do
    dir = Path.join(System.tmp_dir!(), "p1a-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version, "native_components" => native},
      "finished_at" => "2026-07-06T10:00:00Z",
      "systems" => systems
    }

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "#{name}-#{version}",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "l"
      })
  end

  test "package_status_counts buckets one row per package" do
    ingest("allpass", "1.0.0", %{
      "nerves_system_rpi0" => %{"status" => "pass"},
      "host" => %{"status" => "pass"}
    })

    ingest("hasfail", "1.0.0", %{
      "nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"},
      "host" => %{"status" => "pass"}
    })

    counts = Catalog.package_status_counts()
    assert counts.unique == 2
    assert counts.pass == 1
    assert counts.fail == 1
  end

  test "failure_clusters returns title, entries, and a sample log" do
    ingest("clusterpkg", "2.0.0", %{
      "nerves_system_rpi4" => %{
        "status" => "fail",
        "log_tail" => "sh: cannot execute binary file: Exec format error"
      }
    })

    [cluster | _] = Catalog.failure_clusters(10)
    assert cluster.category == "NIF built for wrong architecture"
    assert cluster.title == "NIF built for wrong architecture"
    assert cluster.hint =~ "host"
    assert Enum.any?(cluster.entries, &(&1.package == "clusterpkg" and &1.arch_label == "arm64"))
    assert cluster.sample_log =~ "Exec format error"
  end
end
