defmodule Portal.Workers.ToolchainBenchmarkTest do
  @moduledoc """
  Wall time of real toolchain builds per worker image, for the precompiled
  portability spec's "+50% or less" target (section 11): every package is
  built `NCC_BENCH_RUNS` times (default 3) on every image in
  `NCC_BENCH_IMAGES` (`label=image@elixir/otp,...`) through
  `Portal.Builder.build/1`, with no build cache. The total wall time of each
  build is measured here; the medians and every run's `trace_stats` go to
  `<tmp>/ncc-toolchain-bench/report-<unix time>.json` and a table is printed.
  `NCC_BENCH_PACKAGES` (`name@version:variant,...`) replaces the package
  list.

  Each run also records:

    * `host_ms`, the toolchain run's host phase (`trace_stats`
      `host_compile_sec`: its `deps.get`, the traced compile and any untraced
      fallback), `outside_trace_ms`, that phase less the traced compile, the
      report and the judge (its `deps.get` and fallback), and
      `outside_host_ms`, the rest of the build (container start, project
      setup and the `deps.get`s before the host phase, scanning, archiving);
    * `overflow`, whether the trace overflowed (its problems name it), and
      `report_over_budget`, so a package with a large `priv` that the
      collector digests shows up.

  Excluded by default; on a Linux host with Docker and gVisor:

      NCC_BENCH_IMAGES=untraced=ncc-worker:untraced@1.20/29,judged=ncc-worker:judged@1.20/29,traced=ncc-worker:local@1.20/29 \\
        mix test --include benchmark apps/portal/test/portal/workers/toolchain_benchmark_test.exs
  """
  use Portal.DataCase, async: false

  alias Portal.Builder

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @packages [
    {"jason", "1.4.5", "include"},
    {"decimal", "3.2.0", "include"},
    {"plug", "1.20.3", "include"},
    {"telemetry", "1.4.2", "include"},
    {"phoenix", "1.8.16", "include"},
    {"phoenix", "1.8.16", "exclude"},
    {"ash", "3.37.3", "include"},
    # A large `priv` (its JavaScript bundles and source maps).
    {"phoenix_live_view", "1.2.13", "exclude"}
  ]

  test "median toolchain-run wall time per package, variant and image" do
    assert Builder.build_cache() == nil, "a build cache is configured: the benchmark runs without"
    images = images(System.fetch_env!("NCC_BENCH_IMAGES"))
    runs = String.to_integer(System.get_env("NCC_BENCH_RUNS", "3"))

    rows =
      for {package, version, variant} <- packages(), {label, image, toolchain} <- images do
        samples = for _ <- 1..runs, do: run(package, version, variant, image, toolchain)

        %{
          package: package,
          version: version,
          variant: variant,
          label: label,
          image: image,
          median_ms: median(samples, :ms),
          median_host_ms: median(samples, :host_ms),
          median_outside_trace_ms: median(samples, :outside_trace_ms),
          median_outside_host_ms: median(samples, :outside_host_ms),
          overflow: Enum.any?(samples, & &1.overflow),
          runs: samples
        }
      end

    dir = Path.join(System.tmp_dir!(), "ncc-toolchain-bench")
    File.mkdir_p!(dir)
    path = Path.join(dir, "report-#{System.os_time(:second)}.json")
    File.write!(path, Jason.encode_to_iodata!(rows, pretty: true))

    for r <- rows do
      IO.puts(
        "#{r.package} #{r.variant} #{r.label}: #{r.median_ms} ms " <>
          "(host #{r.median_host_ms}, outside trace #{r.median_outside_trace_ms}, " <>
          "outside host #{r.median_outside_host_ms}#{if r.overflow, do: ", OVERFLOW"})"
      )
    end

    IO.puts("report: #{path}")
  end

  defp packages do
    case System.get_env("NCC_BENCH_PACKAGES") do
      nil ->
        @packages

      spec ->
        for entry <- String.split(spec, ",", trim: true) do
          [name, rest] = String.split(entry, "@", parts: 2)
          [version, variant] = String.split(rest, ":", parts: 2)
          {name, version, variant}
        end
    end
  end

  defp images(spec) do
    for entry <- String.split(spec, ",", trim: true) do
      [label, rest] = String.split(entry, "=", parts: 2)
      [image, toolchain] = String.split(rest, "@", parts: 2)
      [elixir, otp] = String.split(toolchain, "/", parts: 2)
      {label, image, %{elixir: elixir, otp: otp}}
    end
  end

  # The middle sample of `key`, among the runs that have it.
  defp median(samples, key) do
    case samples |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      values -> Enum.at(values, div(length(values), 2))
    end
  end

  defp run(package, version, variant, image, toolchain) do
    run_id = "bench-#{package}-#{System.unique_integer([:positive])}"
    started = System.monotonic_time(:millisecond)

    {:ok, build} =
      Builder.build(%{
        package: package,
        version: version,
        run_id: run_id,
        image: image,
        image_digest: Builder.image_digest(image),
        mode: "toolchain",
        toolchain: toolchain,
        optional_deps: variant
      })

    ms = System.monotonic_time(:millisecond) - started
    Builder.cleanup(run_id)
    assert build.exit_code == 0, "#{image} #{package}: exit #{build.exit_code}\n#{build.log}"
    tb = build.result["toolchain_build"] || %{}
    obs = tb["compile_observations"] || %{}
    stats = obs["trace_stats"] || %{}

    Map.merge(
      %{
        ms: ms,
        status: tb["status"],
        reason: tb["reason"],
        trace_stats: obs["trace_stats"],
        overflow: Enum.any?(obs["problems"] || [], &(inspect(&1) =~ "overflow")),
        report_over_budget: stats["report_over_budget"]
      },
      phases(ms, stats)
    )
  end

  defp phases(ms, %{"host_compile_sec" => sec} = stats) when is_number(sec) do
    host_ms = round(sec * 1000)

    traced =
      Enum.sum(for k <- ~w(compile_ms report_ms judge_ms), is_number(stats[k]), do: stats[k])

    %{host_ms: host_ms, outside_trace_ms: host_ms - traced, outside_host_ms: ms - host_ms}
  end

  defp phases(_ms, _stats), do: %{host_ms: nil, outside_trace_ms: nil, outside_host_ms: nil}
end
