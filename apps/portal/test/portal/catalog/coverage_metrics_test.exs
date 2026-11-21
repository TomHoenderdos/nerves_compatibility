defmodule Portal.Catalog.CoverageMetricsTest do
  # Not async: it swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  import Portal.Test.NotPrecompiledFixtures

  alias Portal.Catalog.{CoverageMetrics, Run, SystemResult}

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(previous,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    :ok
  end

  defp entry(name, versions) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: ~U[2026-11-20 00:00:00Z],
      versions: versions,
      retired: []
    }
  end

  defp host_failed!(name, version) do
    run =
      Ash.create!(
        Run,
        %{
          run_id: "#{name}-#{System.unique_integer([:positive])}",
          package_id: package!(name).id,
          version_tested: version,
          overall_status: :fail,
          finished_at: DateTime.utc_now()
        },
        action: :create,
        domain: Portal.Catalog
      )

    Ash.create!(SystemResult, %{run_id: run.id, system_pkg: "host", status: :fail},
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp forced_skip!(name, version, reason) do
    run =
      Ash.create!(
        Run,
        %{
          run_id: "#{name}-#{System.unique_integer([:positive])}",
          package_id: package!(name).id,
          version_tested: version,
          overall_status: :skipped,
          finished_at: DateTime.utc_now()
        },
        action: :create,
        domain: Portal.Catalog
      )

    Ash.create!(
      SystemResult,
      %{run_id: run.id, system_pkg: "forced@admin@unknown", status: :skipped, log_tail: reason},
      action: :create,
      domain: Portal.Catalog
    )
  end

  # Downloads: served 400 + hidden 100 = 500 of 1,000 counted.
  defp seed! do
    package!("served", 400)
    build!("served", "1.1.0", status: :pass)
    build!("served", "1.1.0", status: :skipped, variant: :without, reason: "no compiled beams")

    # Its newest release is a prerelease; a fresh resolve takes 1.1.0.
    package!("hidden", 100)
    build!("hidden", "1.1.0", status: :pass, variant: :without)

    package!("older_only", 200)
    build!("older_only", "1.0.0", status: :pass)

    package!("unbuilt", 50)

    package!("compile_fail", 150)
    build!("compile_fail", "1.1.0", status: :fail, reason: "compile failed: mix compile exited 1")

    package!("host_fail", 100)
    host_failed!("host_fail", "1.1.0")

    package!("nothing", 60)
    build!("nothing", "1.1.0", status: :skipped, reason: "no compiled beams")

    # Only a named config variant passes: it serves only that config.
    package!("named_only", 0)
    build!("named_only", "1.1.0", status: :pass, config_variant: "phx_prod")

    package!("nerves_system_rpi4", 5_000)
    package!("not_on_hex", 5_000)
    build!("not_on_hex", "1.0.0", status: :pass)

    [
      entry("served", ["1.0.0", "1.1.0"]),
      entry("hidden", ["1.0.0", "1.1.0", "2.0.0-rc.1"]),
      entry("older_only", ["1.0.0", "1.1.0"]),
      entry("unbuilt", ["1.1.0"]),
      entry("compile_fail", ["1.1.0"]),
      entry("host_fail", ["1.1.0"]),
      entry("nothing", ["1.1.0"]),
      entry("named_only", ["1.1.0"]),
      entry("nerves_system_rpi4", ["1.1.0"]),
      entry("not_tracked", ["1.0.0"])
    ]
  end

  test "counts each package at its newest stable release, on each toolchain" do
    registry = seed!()

    assert %{toolchains: [row]} = CoverageMetrics.compute(registry)

    assert row.toolchain == "1.19/28"
    # served, hidden, older_only, unbuilt, compile_fail, host_fail, named_only
    assert row.packages == 7
    assert row.downloads == 1_000
    assert row.served == 2
    assert row.served_downloads == 500
    assert row.download_percent == 50.0
    assert row.nothing_to_compile == 1
    assert row.compile_failures == 2
    assert row.compile_failure_downloads == 250
    # 2 served of the 5 that compile.
    assert row.compile_percent == 40.0
  end

  # Review R12: a compile a signal killed is no verdict on the package
  # (`Portal.Catalog`'s killed-compile rule builds it again), so it is not a
  # compile failure either.
  test "a compile a signal killed is not a compile failure" do
    package!("oom", 10)

    build!("oom", "1.0.0",
      status: :fail,
      reason: "compile failed: host compile failed: mix compile exited with code 137"
    )

    package!("cc1plus", 10)

    build!("cc1plus", "1.0.0",
      status: :fail,
      reason:
        "compile failed: host compile failed: mix compile exited with code 1 " <>
          "(c++: fatal error: Killed signal terminated program cc1plus)"
    )

    package!("broken", 10)

    build!("broken", "1.0.0",
      status: :fail,
      reason: "compile failed: host compile failed: mix compile exited with code 1"
    )

    registry = for name <- ~w(oom cc1plus broken), do: entry(name, ["1.0.0"])

    assert %{toolchains: [%{packages: 3, compile_failures: 1, compile_percent: +0.0}]} =
             CoverageMetrics.compute(registry)
  end

  # No Elixir before 1.22 compiles a Gleam dependency (Mix's `:gleam`
  # manager, elixir-lang/elixir#14262), so a user has no own compile of one
  # and nothing can be served: such a package leaves the second
  # denominator, as a compile failure does, and is counted apart.
  test "a Gleam package is not one that compiles, and is counted apart" do
    package!("served", 100)
    build!("served", "1.0.0", status: :pass)

    package!("gleam_own", 300)
    build!("gleam_own", "1.0.0", status: :skipped, reason: "Package uses gleam build tool")

    package!("gleam_dep", 50)

    build!("gleam_dep", "1.0.0",
      status: :skipped,
      reason: "dependency uses gleam build tool: gleam_stdlib"
    )

    # A full run's forced skip, and no toolchain build of the version.
    package!("gleam_run", 50)
    forced_skip!("gleam_run", "1.0.0", "Package uses gleam build tool (gleam)")

    package!("unbuilt", 100)

    registry =
      for name <- ~w(served gleam_own gleam_dep gleam_run unbuilt), do: entry(name, ["1.0.0"])

    assert %{toolchains: [row]} = CoverageMetrics.compute(registry)
    assert row.packages == 5
    assert row.gleam == 3
    assert row.compile_failures == 0
    # The downloads keep every package: 100 of 600.
    assert row.download_percent == 16.7
    # 1 served of the 2 that can compile.
    assert row.compile_percent == 50.0
  end

  test "an empty registry is all zeros, not an error" do
    assert %{toolchains: [%{packages: 0, download_percent: +0.0, compile_percent: +0.0}]} =
             CoverageMetrics.compute([])
  end

  test "stores what it computed, and reads it back with when" do
    assert CoverageMetrics.latest() == nil

    registry = seed!()
    assert {:ok, _} = registry |> CoverageMetrics.compute() |> CoverageMetrics.store()

    assert %{metrics: %{toolchains: [%{served: 2, download_percent: 50.0}]}, computed_at: at} =
             CoverageMetrics.latest()

    assert %DateTime{} = at
  end

  test "is stored apart from the top packages report" do
    assert {:ok, _} = [] |> CoverageMetrics.compute() |> CoverageMetrics.store()
    assert Portal.Catalog.Coverage.latest() == nil
  end
end
