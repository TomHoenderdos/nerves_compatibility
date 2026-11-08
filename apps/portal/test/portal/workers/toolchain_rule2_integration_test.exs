defmodule Portal.Workers.ToolchainRule2IntegrationTest do
  @moduledoc """
  Rule 2 on real worker images: a toolchain build passes when the static
  rules (R0) and the compile-time trace both pass, whatever rule 1 says.

  phoenix 1.8.16 and phoenix_live_view 1.2.13 call `System.cmd/2` at
  runtime, which rule 1 refused. Under rule 2 phoenix passes with and
  without its optional dependencies, LiveView passes without them, and
  LiveView's `include` build stays skipped because a closure dependency
  (fine) observed the host. Each build goes through
  `Portal.Builder.build/1`, `Ingestion.ingest_toolchain/2` and the format-2
  manifest, on both toolchain images. Excluded from `mix test` by default:

      mix test --include integration apps/portal/test/portal/workers/toolchain_rule2_integration_test.exs

  Requires: Docker running, both images built (`make build` and
  `make build-toolchains`), and network access to Hex.pm (phoenix and
  LiveView ship priv files, checked against their Hex tarballs).

  Prints one line per build with its wall time and compile time.
  """
  use Portal.DataCase, async: false

  alias Portal.Builder
  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, ToolchainBuild}

  @moduletag :integration
  @moduletag timeout: 3_600_000

  @toolchains [
    %{image: "ncc-worker:elixir-1.19-otp-28", elixir: "1.19", otp: "28"},
    %{image: "ncc-worker:local", elixir: "1.20", otp: "29"}
  ]

  @cases [
    {"phoenix", "1.8.16", "include", :with, "pass"},
    {"phoenix", "1.8.16", "exclude", :without, "pass"},
    {"phoenix_live_view", "1.2.13", "exclude", :without, "pass"},
    {"phoenix_live_view", "1.2.13", "include", :with, "skipped"}
  ]

  setup do
    assert docker_running?(), "docker daemon is not running"

    for %{image: image} <- @toolchains do
      assert image_built?(image), "#{image} not built"
    end

    :ok
  end

  test "phoenix and LiveView pass under rule 2 and are served" do
    rows =
      for toolchain <- @toolchains, kase <- @cases do
        {kase, toolchain, build_and_ingest(toolchain, kase)}
      end

    run_ids = fn package, status ->
      for {{^package, _, _, _, ^status}, _, row} <- rows, into: MapSet.new(), do: row.run_id
    end

    phoenix = served("phoenix", "1.8.16")
    live_view = served("phoenix_live_view", "1.2.13")

    # Two pure_elixir builds of phoenix per toolchain, with and without.
    for %{otp: otp} <- @toolchains do
      builds = Enum.filter(phoenix, &(&1["build"]["otp"] == otp))
      assert length(builds) == 2, inspect(Enum.map(builds, & &1["build"]["run_id"]))
      [a, b] = builds
      assert a["build"]["deps"] != b["build"]["deps"]

      assert [_] = Enum.filter(live_view, &(&1["build"]["otp"] == otp))
    end

    assert MapSet.new(phoenix, & &1["build"]["run_id"]) == run_ids.("phoenix", "pass")
    assert MapSet.new(live_view, & &1["build"]["run_id"]) == run_ids.("phoenix_live_view", "pass")

    for run_id <- run_ids.("phoenix_live_view", "skipped") do
      refute Enum.any?(live_view, &(&1["build"]["run_id"] == run_id))
    end
  end

  defp build_and_ingest(%{image: image, elixir: elixir, otp: otp}, kase) do
    {package, version, od, variant, status} = kase
    toolchain = "#{elixir}/#{otp}"
    run_id = "toolchain-r2-#{package}-#{od}-#{elixir}-#{System.unique_integer([:positive])}"
    image_digest = Builder.image_digest(image)
    started = System.monotonic_time(:millisecond)

    assert {:ok, build} =
             Builder.build(%{
               package: package,
               version: version,
               run_id: run_id,
               image: image,
               image_digest: image_digest,
               mode: "toolchain",
               toolchain: %{elixir: elixir, otp: otp},
               optional_deps: od
             })

    wall_ms = System.monotonic_time(:millisecond) - started
    on_exit(fn -> Builder.cleanup(run_id) end)

    assert build.exit_code == 0, "#{image} exited #{build.exit_code}:\n#{build.log}"
    tb = build.result["toolchain_build"]

    label =
      "#{package} #{version} #{toolchain} #{od}: #{inspect(Map.take(tb || %{}, ~w(status reason)))}"

    assert tb["portability_rule"] == 2, label
    assert tb["rule1_reason"] == "calls System.cmd/2", label
    assert tb["status"] == status, label

    if status == "skipped" do
      # fine bakes the build path, so the closure is tainted. In the image
      # lazy_html's precompiled NIF is downloaded over TLS, whose asn1 NIF
      # calls the trace cannot judge, and an incomplete trace is reported
      # before closure taint: the reason is then "could not be judged".
      assert tb["compile_observations"]["taint"]["fine"], label

      assert tb["reason"] == "portability could not be judged" or
               String.starts_with?(tb["reason"], "closure dependency observed the host: fine"),
             label
    else
      assert tb["compile_env_rule"] == 1, label
    end

    assert {:ok, %ToolchainBuild{} = row} =
             Ingestion.ingest_toolchain(build.result, %{
               package: package,
               version: version,
               files_dir: build.files_dir,
               output_dir: build.output_dir,
               toolchain: toolchain,
               builder_version: 1,
               image_digest: image_digest,
               run_id: run_id,
               variant: variant,
               hex_outer_checksum: &Portal.HexDeps.outer_checksum/2,
               hex_tarball: &Portal.HexDeps.tarball/2
             })

    assert row.status == String.to_existing_atom(status), label

    compile_ms = get_in(tb, ["compile_observations", "trace_stats", "compile_ms"])

    IO.puts(
      "#{package} #{version} #{toolchain} #{od} status=#{tb["status"]} " <>
        "wall_ms=#{wall_ms} compile_ms=#{compile_ms}"
    )

    row
  end

  defp served(package, version) do
    assert %{"versions" => %{^version => %{"builds" => builds}}} =
             Catalog.precompiled_manifest_v2(package)

    Enum.filter(builds, &(&1["target"] == "pure_elixir"))
  end

  defp docker_running? do
    match?(
      {_, 0},
      System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true)
    )
  end

  defp image_built?(image) do
    match?({_, 0}, System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true))
  end
end
