defmodule Portal.Workers.ToolchainIntegrationTest do
  @moduledoc """
  End-to-end test of a toolchain build: `Portal.Builder.build/2` with
  `mode: "toolchain"` against two real worker images, then
  `Portal.Catalog.Ingestion.ingest_toolchain/2` into Postgres, then the
  format-2 manifest that the client reads.

  jason 1.4.5 is built on `ncc-worker:elixir-1.19-otp-28` (1.19/28) and on
  `ncc-worker:local` (1.20/29). Excluded from `mix test` by default; run with:

      mix test --include integration apps/portal/test/portal/workers/toolchain_integration_test.exs

  Requires: Docker running, both images built (`make build` and
  `make build-toolchains`), and network access to Hex.pm.

  The rendered v2 document is written to `ncc-toolchain-it/jason-v2.json` under the system tmp dir
  together with a script, `match_check.exs`, that feeds it to the client's
  `ElixirPrecompiled.Match.select/2`. The test prints the command that runs it
  from an `elixir_precompiled` checkout.
  """
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Builder
  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, Ingestion, ToolchainBuild}

  @moduletag :integration
  @moduletag timeout: 600_000

  @package "jason"
  @version "1.4.5"

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

  test "builds jason on two toolchains and publishes both as pure_elixir builds" do
    rows = Enum.map(@toolchains, &build_and_ingest/1)

    v2 = Catalog.precompiled_manifest_v2(@package)
    assert %{"format" => 2, "versions" => %{@version => %{"builds" => builds}}} = v2

    pure = Enum.filter(builds, &(&1["target"] == "pure_elixir"))
    assert length(pure) == 2

    elixirs = Enum.map(pure, & &1["build"]["elixir"])
    assert Enum.uniq(elixirs) == elixirs
    assert Enum.any?(elixirs, &String.starts_with?(&1, "1.19."))
    assert Enum.any?(elixirs, &String.starts_with?(&1, "1.20."))

    for build <- pure do
      expected_otp =
        if String.starts_with?(build["build"]["elixir"], "1.19."), do: "28", else: "29"

      assert build["build"]["otp"] == expected_otp
      assert build["build"]["dep_env"] == "prod"
      assert is_list(build["ebin"]) and build["ebin"] != []
    end

    # A toolchain build is not a full run, so format 1 has nothing for jason.
    assert Catalog.precompiled_manifest(@package) == nil

    write_client_check(v2, Enum.find(rows, &(&1.toolchain == "1.19/28")))
  end

  defp build_and_ingest(%{image: image, elixir: elixir, otp: otp}) do
    toolchain = "#{elixir}/#{otp}"
    run_id = "toolchain-it-#{@package}-#{elixir}-#{otp}-#{System.unique_integer([:positive])}"
    image_digest = Builder.image_digest(image)

    assert {:ok, build} =
             Builder.build(%{
               package: @package,
               version: @version,
               run_id: run_id,
               image: image,
               image_digest: image_digest,
               mode: "toolchain",
               toolchain: %{elixir: elixir, otp: otp}
             })

    on_exit(fn -> Builder.cleanup(run_id) end)

    assert build.exit_code == 0, "#{image} exited #{build.exit_code}:\n#{build.log}"
    assert %{"scope" => "toolchain", "toolchain_build" => tb} = build.result
    assert tb["status"] == "pass", inspect(tb)

    assert {:ok, %ToolchainBuild{} = row} =
             Ingestion.ingest_toolchain(build.result, %{
               files_dir: build.files_dir,
               output_dir: build.output_dir,
               toolchain: toolchain,
               builder_version: 1,
               image_digest: image_digest,
               run_id: run_id
             })

    assert row.status == :pass
    assert String.starts_with?(row.elixir, elixir <> ".")
    assert row.otp == otp
    assert %{"decimal" => %{"version" => _, "checksum" => _}} = row.deps_lock
    assert is_binary(row.package_checksum)

    memberships =
      ArtifactMembership
      |> Ash.Query.filter(toolchain_build_id == ^row.id)
      |> Ash.read!(domain: Portal.Catalog)

    assert memberships != []

    IO.puts(
      "toolchain #{toolchain} on #{image}: status=#{row.status} elixir=#{row.elixir} " <>
        "otp=#{row.otp} memberships=#{length(memberships)}"
    )

    row
  end

  # Writes the v2 document and a script for the client's Match.select/2,
  # with the lock tuples a project locking this jason and decimal would have.
  # Match reads only the version and outer checksum of each lock entry and
  # jason's declared deps, so the inner checksum is a placeholder.
  defp write_client_check(v2, row) do
    dir = Path.join(System.tmp_dir!(), "ncc-toolchain-it")
    File.mkdir_p!(dir)
    doc_path = Path.join(dir, "jason-v2.json")
    script_path = Path.join(dir, "match_check.exs")
    File.write!(doc_path, Jason.encode!(v2, pretty: true))

    %{"decimal" => %{"version" => decimal_version, "checksum" => decimal_checksum}} =
      row.deps_lock

    jason_lock =
      {:hex, :jason, @version, "inner", [:mix],
       [{:decimal, "~> 1.0 or ~> 2.0 or ~> 3.0", [hex: :decimal, repo: "hexpm", optional: true]}],
       "hexpm", row.package_checksum}

    decimal_lock =
      {:hex, :decimal, decimal_version, "inner", [:mix], [], "hexpm", decimal_checksum}

    script = """
    doc = File.read!(#{inspect(doc_path)}) |> :json.decode()
    {:ok, m} = ElixirPrecompiled.Manifest.normalize(doc)
    jason = #{inspect(jason_lock, limit: :infinity, printable_limit: :infinity)}
    decimal = #{inspect(decimal_lock, limit: :infinity, printable_limit: :infinity)}

    m
    |> ElixirPrecompiled.Match.select(%{
      name: "jason",
      version: #{inspect(@version)},
      lock_entry: jason,
      lock: %{jason: jason, decimal: decimal},
      system: {"host", ""},
      elixir: #{inspect(row.elixir)},
      otp: #{inspect(row.otp)},
      dep_env: "prod",
      config: fn _, _ -> :error end
    })
    |> then(fn {:ok, build, target} -> {:ok, build["build"], target}; other -> other end)
    |> IO.inspect(label: "Match.select")
    """

    File.write!(script_path, script)
    IO.puts("v2 document: #{doc_path}")
    IO.puts("client check: cd ~/Projects/elixir_precompiled && mix run --no-start #{script_path}")
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
