defmodule Portal.Workers.ToolchainConfigVariantsIntegrationTest do
  @moduledoc """
  End-to-end test of a toolchain build's config variants on real worker
  images: heroicons 0.5.7, whose closure reads LiveView's compile-time
  config, is built in `default` and then in each named variant
  (`Compatibility.ConfigVariants.names/0`) with `Portal.Builder.build/2`,
  ingested with `Portal.Catalog.Ingestion.ingest_toolchain/2`, and served by
  `Portal.Catalog.precompiled_manifest_v2/1` beside the default.

  Built on `ncc-worker:elixir-1.19-otp-28` (1.19/28) and on
  `ncc-worker:local` (1.20/29). Excluded from `mix test` by default; run with:

      mix test --include integration apps/portal/test/portal/workers/toolchain_config_variants_integration_test.exs

  Requires: Docker running, both images built (`make build` and
  `make build-toolchains`), and network access to Hex.pm.

  Prints one line per build with its wall time and the traced compile's
  `compile_ms`.
  """
  use Portal.DataCase, async: false

  alias Compatibility.ConfigVariants
  alias Portal.Builder
  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, ToolchainBuild}

  @moduletag :integration
  @moduletag timeout: 5_400_000

  @package "heroicons"
  @version "0.5.7"

  # The one module that `use`s Phoenix.Component, whose compiled templates
  # depend on LiveView's compile-time config. Every other file is the same
  # in every variant.
  @config_beam "ebin/Elixir.Heroicons.beam"

  @toolchains [
    %{image: "ncc-worker:elixir-1.19-otp-28", elixir: "1.19", otp: "28"},
    %{image: "ncc-worker:local", elixir: "1.20", otp: "29"}
  ]

  setup do
    assert docker_running?(), "docker daemon is not running"

    for %{image: image} <- @toolchains do
      assert image_built?(image), "#{image} not built"
    end

    :ok
  end

  test "builds heroicons in every config variant on two toolchains and serves them beside the default" do
    for toolchain <- @toolchains, do: build_variants(toolchain)
  end

  defp build_variants(%{otp: otp} = toolchain) do
    {default_build, default_row} = build_and_ingest(toolchain, nil)

    assert default_row.compile_env_rule == 1

    assert ConfigVariants.wanted(ConfigVariants.reads(default_row.compile_env)) ==
             ConfigVariants.names()

    # Lets a named variant share the default's five-column identity.
    Portal.PrecompiledFixtures.drop_legacy_identity_index!()

    default_files = files(default_build)

    for name <- ConfigVariants.names() do
      {build, row} = build_and_ingest(toolchain, name)

      assert build.result["toolchain_build"]["config_variant"] == name
      assert :ok = ConfigVariants.overlay_recorded(name, row.compile_env)

      variant_files = files(build)
      assert Map.keys(variant_files) == Map.keys(default_files)

      assert Map.delete(variant_files, @config_beam) == Map.delete(default_files, @config_beam),
             "#{name}: a file other than #{@config_beam} differs from the default's"

      IO.puts(
        "heroicons #{@version} #{toolchain_name(toolchain)} #{name}: " <>
          "#{@config_beam} " <>
          if(variant_files[@config_beam] == default_files[@config_beam],
            do: "same as default",
            else: "differs from default"
          )
      )
    end

    assert %{"versions" => %{@version => %{"builds" => builds}}} =
             Catalog.precompiled_manifest_v2(@package)

    served =
      Enum.filter(builds, &(&1["target"] == "pure_elixir" and &1["build"]["otp"] == otp))

    assert length(served) == 4, inspect(served, pretty: true)

    assert Enum.sort(variant_names(served)) ==
             Enum.sort([ConfigVariants.default() | ConfigVariants.names()])
  end

  defp build_and_ingest(%{image: image, elixir: elixir, otp: otp} = toolchain, config_variant) do
    name = config_variant || ConfigVariants.default()
    toolchain = toolchain_name(toolchain)

    run_id =
      "toolchain-cv-it-#{@package}-#{elixir}-#{otp}-#{name}-#{System.unique_integer([:positive])}"

    image_digest = Builder.image_digest(image)
    started = System.monotonic_time(:millisecond)

    assert {:ok, build} =
             Builder.build(%{
               package: @package,
               version: @version,
               run_id: run_id,
               image: image,
               image_digest: image_digest,
               mode: "toolchain",
               toolchain: %{elixir: elixir, otp: otp},
               optional_deps: "include",
               config_variant: config_variant
             })

    wall_ms = System.monotonic_time(:millisecond) - started
    on_exit(fn -> Builder.cleanup(run_id) end)

    assert build.exit_code == 0, "#{image} #{name} exited #{build.exit_code}:\n#{build.log}"
    assert %{"scope" => "toolchain", "toolchain_build" => tb} = build.result
    assert tb["status"] == "pass", inspect(tb)
    assert tb["compile_env_rule"] == 1, inspect(tb)

    opts =
      %{
        package: @package,
        version: @version,
        files_dir: build.files_dir,
        output_dir: build.output_dir,
        toolchain: toolchain,
        builder_version: 1,
        image_digest: image_digest,
        run_id: run_id,
        variant: :with,
        hex_outer_checksum: &Portal.HexDeps.outer_checksum/2,
        hex_tarball: &Portal.HexDeps.tarball/2
      }
      |> then(&if(config_variant, do: Map.put(&1, :config_variant, config_variant), else: &1))

    assert {:ok, %ToolchainBuild{status: :pass} = row} =
             Ingestion.ingest_toolchain(build.result, opts)

    assert row.config_variant == name

    compile_ms = get_in(tb, ["compile_observations", "trace_stats", "compile_ms"])

    IO.puts(
      "heroicons #{@version} #{toolchain} #{name} wall_ms=#{wall_ms} compile_ms=#{compile_ms}"
    )

    {build, row}
  end

  # Every published file by path, with its digest.
  defp files(build) do
    for {_kind, entries} <- build.result["toolchain_build"]["file_manifest"],
        %{"path" => path, "sha256" => sha256} <- entries,
        into: %{},
        do: {path, sha256}
  end

  defp variant_names(builds),
    do: Enum.map(builds, &(&1["build"]["config_variant"] || ConfigVariants.default()))

  defp toolchain_name(%{elixir: elixir, otp: otp}), do: "#{elixir}/#{otp}"

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
