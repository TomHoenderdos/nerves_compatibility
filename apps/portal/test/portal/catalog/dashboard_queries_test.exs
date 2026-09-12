defmodule Portal.Catalog.DashboardQueriesTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, version, systems, native, finished) do
    dir = Path.join(System.tmp_dir!(), "dq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version, "native_components" => native},
      "finished_at" => finished,
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

  test "queries aggregate seeded runs" do
    ingest(
      "passer",
      "1.0.0",
      %{
        "nerves_system_rpi0" => %{"status" => "pass"},
        "nerves_system_x86_64" => %{"status" => "pass"}
      },
      %{"nif_language" => "rust", "port_languages" => []},
      "2026-07-02T10:00:00Z"
    )

    ingest(
      "failer",
      "2.0.0",
      %{
        "nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"},
        "nerves_system_x86_64" => %{"status" => "fail"}
      },
      nil,
      "2026-07-03T10:00:00Z"
    )

    rates = Catalog.pass_rate_per_system()
    rpi0 = Enum.find(rates, &(&1.system_pkg == "nerves_system_rpi0"))
    assert rpi0.total == 2 and rpi0.pass == 1

    recent_fail = Catalog.recent_runs(:fail, 5)
    assert hd(recent_fail).package == "failer"

    recent_pass = Catalog.recent_runs(:pass, 5)
    assert Enum.any?(recent_pass, &(&1.package == "passer"))

    clusters = Catalog.failure_clusters(10)
    arch = Enum.find(clusters, &(&1.category == "NIF built for wrong architecture"))
    assert arch.systems == 1 and arch.packages == 1

    native = Catalog.native_breakdown()
    assert Enum.any?(native, &(&1.language == "rust" and &1.packages == 1))
  end

  test "recent_runs shows a package once, at its newest run" do
    systems = %{"nerves_system_x86_64" => %{"status" => "pass"}}

    for {version, finished} <- [
          {"1.0.0", "2026-07-01T10:00:00Z"},
          {"1.0.1", "2026-07-02T10:00:00Z"},
          {"1.0.2", "2026-07-03T10:00:00Z"}
        ] do
      ingest("repeat", version, systems, nil, finished)
    end

    ingest("other", "9.0.0", systems, nil, "2026-07-04T10:00:00Z")

    recent = Catalog.recent_runs(:pass, 10)

    assert Enum.count(recent, &(&1.package == "repeat")) == 1
    assert Enum.find(recent, &(&1.package == "repeat")).version == "1.0.2"
    assert Enum.any?(recent, &(&1.package == "other"))
  end

  # A skipped package still has to carry one system entry, so the worker writes
  # the synthetic `forced@admin@unknown`. It is not a Nerves system and cannot
  # pass, so it has no place in a per-system pass rate -- in production it was
  # 279 rows of permanent 0%.
  test "the synthetic forced bucket is not a system" do
    ingest(
      "skipper",
      "1.0.0",
      %{"forced@admin@unknown" => %{"status" => "skipped"}},
      nil,
      "2026-07-04T10:00:00Z"
    )

    ingest(
      "builder",
      "1.0.0",
      %{"nerves_system_rpi0" => %{"status" => "pass"}},
      nil,
      "2026-07-04T11:00:00Z"
    )

    rates = Catalog.pass_rate_per_system()

    assert Enum.map(rates, & &1.system_pkg) == ["nerves_system_rpi0"]
  end
end
