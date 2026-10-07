defmodule Portal.Catalog.DashboardCharacterizationTest do
  @moduledoc """
  The whole of `Portal.Catalog.dashboard/2`, `failure_clusters/1` and
  `package_status_counts/0`, pinned over one catalog that exercises every rule
  they apply: the latest run per package (including an unfinished one, which
  sorts first), every rollup bucket, assessments and the synthetic `forced`
  system, cluster ties and the limit, and the per-package dedup of recent runs.

  Written against the Elixir fold before the aggregates moved into SQL, and
  passing there, so the rewrite has to reproduce the old output exactly.
  """
  use Portal.DataCase, async: false

  import Portal.PackageListingFixtures

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, run_id, finished_at, systems, native \\ nil) do
    dir = Path.join(System.tmp_dir!(), "dch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0", "native_components" => native},
          "finished_at" => finished_at,
          "systems" => systems
        },
        %{run_id: run_id, image_digest: "sha256:x", files_dir: dir, log: "l"}
      )
  end

  defp fail(log), do: %{"status" => "fail", "log_tail" => log}

  defp seed do
    # Superseded: its failure must not reach a cluster.
    ingest("alpha", "alpha-old", "2026-07-01T10:00:00Z", %{
      "nerves_system_rpi4" => fail("Exec format error")
    })

    ingest("alpha", "alpha-new", "2026-07-05T10:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "pass"},
      "nerves_system_x86_64" => %{"status" => "pass"},
      "host" => %{"status" => "pass"}
    })

    ingest(
      "bravo",
      "bravo-1",
      "2026-07-04T10:00:00Z",
      %{
        "nerves_system_rpi4" => fail("sh: Exec format error"),
        "nerves_system_rpi0" => %{"status" => "error", "log_tail" => "** (CompileError) x"},
        "nerves_system_x86_64" => %{"status" => "pass"}
      },
      %{"nif_language" => "rust", "port_languages" => []}
    )

    ingest(
      "charlie",
      "charlie-1",
      "2026-07-03T10:00:00Z",
      %{
        "nerves_system_rpi4" => fail("no precompiled NIF here"),
        "nerves_system_x86_64" => %{"status" => "pass"}
      },
      %{"nif_language" => "c", "port_languages" => ["c", "rust"]}
    )

    ingest(
      "delta",
      "delta-1",
      "2026-07-02T10:00:00Z",
      %{
        "nerves_system_rpi4" => %{"status" => "pass"},
        "nerves_system_x86_64" => %{"status" => "skipped"}
      },
      %{"nif_language" => nil, "port_languages" => ["zig", nil]}
    )

    ingest("echo", "echo-1", "2026-07-02T11:00:00Z", %{
      "forced@admin@unknown" => %{"status" => "skipped"}
    })

    ingest("foxtrot", "foxtrot-1", "2026-07-02T12:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "unknown"}
    })

    # The unfinished run is golf's latest (DESC puts NULL first), so golf is
    # failing, but only the finished pass can appear among recent runs.
    ingest("golf", "golf-done", "2026-07-06T10:00:00Z", %{
      "nerves_system_rpi3" => %{"status" => "pass"}
    })

    ingest("golf", "golf-open", nil, %{"nerves_system_rpi3" => fail("Exec format error")})

    ingest("hotel", "hotel-1", "2026-07-02T13:00:00Z", %{
      "pure_elixir" => %{"status" => "pass"},
      "host" => %{"status" => "pass"}
    })

    package_fixture("india")

    ingest("juliet", "juliet-1", "2026-07-01T12:00:00Z", %{
      "nerves_system_rpi4" => fail("== Compilation error in file lib/a.ex ==\nmore"),
      "nerves_system_rpi5" => fail("== Compilation error")
    })

    ingest("kilo", "kilo-1", "2026-07-01T13:00:00Z", %{
      "nerves_system_rpi4" => fail("boom")
    })

    ingest("lima", "lima-1", "2026-07-01T14:00:00Z", %{
      "nerves_system_x86_64" => %{"status" => "error", "log_tail" => "error loading NIF"}
    })
  end

  defp entry(package, arch_label) do
    %{package: package, version: "1.0.0", arch_label: arch_label, nif_language: nil, detail: nil}
  end

  @compile_cluster %{
    category: "Compilation error",
    title: "Compilation error",
    hint:
      "The package's own source failed to compile — often a syntax issue triggered by a newer Elixir, or a missing macro dependency.",
    systems: 3,
    packages: 2,
    sample_log: "** (CompileError) x"
  }

  @arch_cluster %{
    category: "NIF built for wrong architecture",
    title: "NIF built for wrong architecture",
    hint:
      "A dependency's NIF was compiled for the host, not the Nerves target — the scrub-otp step rejects it at firmware-build time. Usually fixable by forcing a clean rebuild of the dep for the target.",
    systems: 2,
    packages: 2,
    sample_log: "Exec format error"
  }

  @precompiled_cluster %{
    category: "Precompiled NIF missing for target",
    title: "Precompiled NIF missing for this target",
    hint:
      "The package ships a precompiled NIF but no build exists for the Nerves target triple. The package vendor would need to add the triple to their release.",
    systems: 2,
    packages: 2,
    sample_log: "error loading NIF"
  }

  @other_cluster %{
    category: "Other / unclassified",
    title: "Other / unclassified",
    hint:
      "Build failures that don't match a known pattern. See the representative log for the specific cause.",
    systems: 1,
    packages: 1,
    sample_log: "boom"
  }

  defp without_entries(clusters), do: Enum.map(clusters, &Map.delete(&1, :entries))

  # Entries come out in `system_pkg` order; packages sharing a system have no
  # order between them, so compare those as sets.
  defp entries_by_cluster(clusters) do
    Map.new(clusters, fn c ->
      {c.category, Enum.sort_by(c.entries, &{&1.arch_label, &1.package})}
    end)
  end

  defp utc(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    %{dt | microsecond: {0, 6}}
  end

  test "package_status_counts buckets each package by its latest run" do
    seed()

    # india has no run and is not counted; golf counts as failing.
    assert Catalog.package_status_counts() == %{
             unique: 11,
             pass: 2,
             fail: 6,
             partial: 1,
             skipped: 1,
             unknown: 1
           }
  end

  test "failure_clusters ranks by systems, then by category name, and keeps every entry" do
    seed()

    clusters = Catalog.failure_clusters(10)

    assert without_entries(clusters) == [
             @compile_cluster,
             @arch_cluster,
             @precompiled_cluster,
             @other_cluster
           ]

    assert entries_by_cluster(clusters) == %{
             "Compilation error" => [
               entry("bravo", "arm32"),
               entry("juliet", "arm64"),
               entry("juliet", "arm64")
             ],
             "NIF built for wrong architecture" => [
               entry("golf", "arm32"),
               entry("bravo", "arm64")
             ],
             "Precompiled NIF missing for target" => [
               entry("charlie", "arm64"),
               entry("lima", "x86_64")
             ],
             "Other / unclassified" => [entry("kilo", "arm64")]
           }

    # Within a cluster the entries follow `system_pkg`.
    compile = Enum.find(clusters, &(&1.category == "Compilation error"))
    assert Enum.map(compile.entries, & &1.package) == ["bravo", "juliet", "juliet"]
  end

  test "failure_clusters stops at the limit" do
    seed()

    assert clusters = Catalog.failure_clusters(2)
    assert without_entries(clusters) == [@compile_cluster, @arch_cluster]
  end

  test "dashboard renders the same numbers" do
    seed()

    data = Catalog.dashboard(3, 10)

    assert data.counts == Catalog.package_status_counts()

    assert without_entries(data.clusters) == [
             @compile_cluster,
             @arch_cluster,
             @precompiled_cluster
           ]

    assert data.native ==
             [
               %{language: "Pure Elixir / none", packages: 9},
               %{language: "c", packages: 1},
               %{language: "rust", packages: 2},
               %{language: "zig", packages: 1}
             ]
             |> Enum.sort_by(& &1.packages, :desc)

    assert data.rates == [
             %{system_pkg: "host", pass: 2, total: 2, rate: 1.0},
             %{system_pkg: "nerves_system_rpi0", pass: 0, total: 1, rate: 0.0},
             %{system_pkg: "nerves_system_rpi3", pass: 0, total: 1, rate: 0.0},
             %{system_pkg: "nerves_system_rpi4", pass: 2, total: 7, rate: 2 / 7},
             %{system_pkg: "nerves_system_rpi5", pass: 0, total: 1, rate: 0.0},
             %{system_pkg: "nerves_system_x86_64", pass: 3, total: 5, rate: 3 / 5}
           ]

    assert data.recent_pass == [
             %{
               package: "golf",
               version: "1.0.0",
               finished_at: utc("2026-07-06T10:00:00Z"),
               overall_status: :pass
             },
             %{
               package: "alpha",
               version: "1.0.0",
               finished_at: utc("2026-07-05T10:00:00Z"),
               overall_status: :pass
             },
             %{
               package: "bravo",
               version: "1.0.0",
               finished_at: utc("2026-07-04T10:00:00Z"),
               overall_status: :pass
             },
             %{
               package: "charlie",
               version: "1.0.0",
               finished_at: utc("2026-07-03T10:00:00Z"),
               overall_status: :pass
             },
             %{
               package: "hotel",
               version: "1.0.0",
               finished_at: utc("2026-07-02T13:00:00Z"),
               overall_status: :pass
             },
             %{
               package: "delta",
               version: "1.0.0",
               finished_at: utc("2026-07-02T10:00:00Z"),
               overall_status: :pass
             }
           ]

    # alpha's old failure is a run of its own; `recent_runs` reads every run,
    # not only the latest.
    assert data.recent_fail == [
             %{
               package: "lima",
               version: "1.0.0",
               finished_at: utc("2026-07-01T14:00:00Z"),
               overall_status: :error
             },
             %{
               package: "kilo",
               version: "1.0.0",
               finished_at: utc("2026-07-01T13:00:00Z"),
               overall_status: :fail
             },
             %{
               package: "juliet",
               version: "1.0.0",
               finished_at: utc("2026-07-01T12:00:00Z"),
               overall_status: :fail
             },
             %{
               package: "alpha",
               version: "1.0.0",
               finished_at: utc("2026-07-01T10:00:00Z"),
               overall_status: :fail
             }
           ]

    assert data.last_run == "2026-07-06T10:00:00.000000Z"
  end

  test "recent runs stop at the limit" do
    seed()

    data = Catalog.dashboard(3, 2)
    assert Enum.map(data.recent_pass, & &1.package) == ["golf", "alpha"]
    assert Enum.map(data.recent_fail, & &1.package) == ["lima", "kilo"]
  end

  test "an empty catalog" do
    data = Catalog.dashboard(3, 10)

    assert data == %{
             counts: %{unique: 0, pass: 0, fail: 0, partial: 0, skipped: 0, unknown: 0},
             clusters: [],
             native: [],
             rates: [],
             recent_pass: [],
             recent_fail: [],
             last_run: nil
           }

    assert Catalog.failure_clusters(50) == []
  end
end
