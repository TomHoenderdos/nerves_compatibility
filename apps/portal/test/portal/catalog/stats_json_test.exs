defmodule Portal.Catalog.StatsJsonTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, run_id, finished_at, systems) do
    dir = Path.join(System.tmp_dir!(), "stats-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => finished_at,
          "systems" => systems
        },
        %{run_id: run_id, image_digest: "sha256:x", files_dir: dir, log: "l"}
      )
  end

  # Every run counts, not only the latest per package, and every status lands
  # in its own bucket.
  test "counts every system result of every run, per status and per system" do
    ingest("a", "a-1", "2026-07-01T10:00:00.123456Z", %{
      "nerves_system_rpi4" => %{"status" => "pass", "system_version" => "1.0.0"},
      "nerves_system_x86_64" => %{"status" => "fail", "system_version" => "1.0.0"},
      "host" => %{"status" => "pass", "system_version" => nil}
    })

    ingest("a", "a-2", "2026-07-03T09:30:00.654321Z", %{
      "nerves_system_rpi4" => %{"status" => "error", "system_version" => "1.0.0"},
      "nerves_system_rpi4_new" => %{"status" => "skipped", "system_version" => "2.0.0"}
    })

    ingest("b", "b-1", "2026-07-02T10:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "unknown", "system_version" => "1.0.0"},
      "pure_elixir" => %{"status" => "pass", "system_version" => nil}
    })

    stats = Catalog.stats_json()

    assert stats.schema == 2
    assert is_binary(stats.generated_at)

    assert stats.counts == %{
             "pass" => 3,
             "fail" => 1,
             "error" => 1,
             "skipped" => 1,
             "unknown" => 1,
             "total" => 7
           }

    zero = %{"pass" => 0, "fail" => 0, "error" => 0, "skipped" => 0, "unknown" => 0}

    assert stats.by_system == %{
             "nerves_system_rpi4@1.0.0" => %{zero | "pass" => 1, "error" => 1, "unknown" => 1},
             "nerves_system_x86_64@1.0.0" => %{zero | "fail" => 1},
             "nerves_system_rpi4_new@2.0.0" => %{zero | "skipped" => 1},
             "host@" => %{zero | "pass" => 1}
           }

    assert stats.last_run_finished_at == "2026-07-03T09:30:00.654321Z"
  end

  # A partial run copies the systems it did not build from the previous run;
  # those copies were never built again, so they are not new results.
  test "systems an argus-only run carried over are not counted again" do
    ingest("carried", "c-1", "2026-07-01T10:00:00Z", %{
      "host" => %{"status" => "pass"},
      "nerves_system_rpi4" => %{"status" => "pass", "system_version" => "1.0.0"},
      "nerves_system_bbb" => %{"status" => "fail", "system_version" => "1.0.0"}
    })

    before = Catalog.stats_json()

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "carried", "version" => "1.0.0"},
          "finished_at" => "2026-07-02T10:00:00Z",
          "scope" => "argus_only",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{run_id: "c-2", image_digest: "sha256:x", files_dir: System.tmp_dir!()}
      )

    stats = Catalog.stats_json()

    assert Map.delete(stats.by_system, "host@") == Map.delete(before.by_system, "host@")
    assert stats.by_system["host@"]["pass"] == 2
    assert stats.counts["total"] == before.counts["total"] + 1
  end

  test "an empty catalog" do
    stats = Catalog.stats_json()

    assert stats.counts == %{
             "pass" => 0,
             "fail" => 0,
             "error" => 0,
             "skipped" => 0,
             "unknown" => 0,
             "total" => 0
           }

    assert stats.by_system == %{}
    assert stats.last_run_finished_at == nil
  end
end
