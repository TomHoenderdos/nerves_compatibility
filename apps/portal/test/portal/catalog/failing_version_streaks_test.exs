defmodule Portal.Catalog.FailingVersionStreaksTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  @fail %{
    "nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"},
    "nerves_system_x86_64" => %{"status" => "fail", "log_tail" => "Exec format error"}
  }
  @pass %{"nerves_system_rpi0" => %{"status" => "pass"}}

  defp ingest(name, version, systems, finished, run_suffix \\ "") do
    dir = Path.join(System.tmp_dir!(), "streak-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version},
      "finished_at" => finished,
      "systems" => systems
    }

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "#{name}-#{version}#{run_suffix}",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "l"
      })
  end

  test "counts consecutive failing versions from the newest down, with a category per version" do
    ingest("stuck", "1.0.0", @fail, "2026-07-01T10:00:00Z")
    ingest("stuck", "1.1.0", @fail, "2026-07-02T10:00:00Z")
    ingest("stuck", "1.2.0", @fail, "2026-07-03T10:00:00Z")

    assert [%{package: "stuck", streak: 3, versions_tested: 3, chain: chain} = entry] =
             Catalog.failing_version_streaks()

    assert entry.last_failed_at == ~U[2026-07-03 10:00:00.000000Z]

    assert Enum.map(chain, &{&1.version, &1.status}) ==
             [{"1.2.0", :fail}, {"1.1.0", :fail}, {"1.0.0", :fail}]

    assert Enum.all?(chain, &(&1.category == "NIF built for wrong architecture"))
  end

  test "a passing version ends the streak" do
    ingest("recovered", "1.0.0", @fail, "2026-07-01T10:00:00Z")
    ingest("recovered", "1.1.0", @fail, "2026-07-02T10:00:00Z")
    ingest("recovered", "1.2.0", @pass, "2026-07-03T10:00:00Z")

    ingest("relapsed", "1.0.0", @fail, "2026-07-01T10:00:00Z")
    ingest("relapsed", "1.1.0", @pass, "2026-07-02T10:00:00Z")
    ingest("relapsed", "1.2.0", @fail, "2026-07-03T10:00:00Z")
    ingest("relapsed", "1.3.0", @fail, "2026-07-04T10:00:00Z")

    assert [%{package: "relapsed", streak: 2, versions_tested: 4, chain: chain}] =
             Catalog.failing_version_streaks()

    assert Enum.map(chain, &{&1.version, &1.status}) ==
             [{"1.3.0", :fail}, {"1.2.0", :fail}, {"1.1.0", :pass}, {"1.0.0", :fail}]
  end

  test "a version counts by its latest run" do
    ingest("rerun", "1.0.0", @fail, "2026-07-01T10:00:00Z")
    ingest("rerun", "1.1.0", @fail, "2026-07-02T10:00:00Z")
    ingest("rerun", "1.1.0", @pass, "2026-07-05T10:00:00Z", "-again")

    assert Catalog.failing_version_streaks() == []
    assert [%{package: "rerun", streak: 0}] = Catalog.failing_version_streaks(min_streak: 0)
  end

  test "orders by streak length, caps the packages and the chain" do
    for {name, n} <- [{"two", 2}, {"four", 4}, {"three", 3}], i <- 1..n do
      ingest(name, "0.#{i}.0", @fail, "2026-07-0#{i}T10:00:00Z")
    end

    assert [%{package: "four", chain: chain}, %{package: "three"}] =
             Catalog.failing_version_streaks(limit: 2, versions: 3)

    assert length(chain) == 3
  end
end
