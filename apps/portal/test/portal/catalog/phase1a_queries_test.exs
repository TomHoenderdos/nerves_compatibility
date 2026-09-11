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

  # `sample_log` is the one dashboard consumer of `log_tail`, and `log_tail` is
  # deliberately no longer loaded onto the annotated rows the clusters are built
  # from. These pin the behaviour the separate fetch has to reproduce.
  describe "sample_log" do
    test "picks the shortest non-empty log_tail in the cluster" do
      ingest("longpkg", "1.0.0", %{
        "nerves_system_rpi4" => %{
          "status" => "fail",
          "log_tail" => String.duplicate("noise\n", 50) <> "Exec format error, long one"
        }
      })

      ingest("shortpkg", "1.0.0", %{
        "nerves_system_rpi4" => %{
          "status" => "fail",
          "log_tail" => "Exec format error, short one"
        }
      })

      [cluster | _] = Catalog.failure_clusters(10)
      assert cluster.systems == 2
      assert cluster.sample_log == "Exec format error, short one"
    end

    test "skips empty and missing log tails rather than returning them" do
      # The `error` field is what puts all three in one cluster: the classifier
      # reads it alongside `log_tail`, so two of them can land in the same
      # category while carrying no tail of their own.
      ingest("emptytail", "1.0.0", %{
        "nerves_system_rpi4" => %{
          "status" => "fail",
          "error" => "Exec format error",
          "log_tail" => ""
        }
      })

      ingest("niltail", "1.0.0", %{
        "nerves_system_rpi4" => %{"status" => "fail", "error" => "Exec format error"}
      })

      ingest("realtail", "1.0.0", %{
        "nerves_system_rpi4" => %{
          "status" => "fail",
          "log_tail" => "sh: cannot execute binary file: Exec format error"
        }
      })

      [cluster | _] = Catalog.failure_clusters(10)
      assert cluster.systems == 3
      assert cluster.sample_log == "sh: cannot execute binary file: Exec format error"
    end

    test "is nil when no system in the cluster carries a log tail" do
      ingest("notail", "1.0.0", %{
        "nerves_system_rpi4" => %{"status" => "fail", "log_tail" => ""}
      })

      [cluster | _] = Catalog.failure_clusters(10)
      assert cluster.sample_log == nil
    end

    test "keeps only the last 40 lines of the chosen tail" do
      body = Enum.map_join(1..100, "\n", &"line #{&1}") <> "\nExec format error"

      ingest("longtail", "1.0.0", %{
        "nerves_system_rpi4" => %{"status" => "fail", "log_tail" => body}
      })

      [cluster | _] = Catalog.failure_clusters(10)
      lines = String.split(cluster.sample_log, "\n")
      assert length(lines) == 40
      assert List.first(lines) == "line 62"
      assert List.last(lines) == "Exec format error"
    end
  end
end
