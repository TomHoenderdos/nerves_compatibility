defmodule Portal.PinnedIngestTest do
  # Pinned builds (lock-driven builds spec, phase 1): ingested through the
  # toolchain build's own staging and gates into `catalog_pinned_builds`,
  # never as a run or a toolchain build, and stored as a pass only when the
  # lock they compiled against is exactly the set.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, DeterministicBuild, Ingestion, PinnedBuild}

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def unique,
    do:
      "pnpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3))}"

  def tmp(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  def files(blobs) do
    dir = tmp("pn-files")
    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  def pins(
        name,
        deps \\ [
          %{"name" => "decimal", "hex" => "decimal", "version" => "2.3.0", "checksum" => @b}
        ]
      ) do
    hash =
      Compatibility.Pins.hash(%{
        package: name,
        version: "1.0.0",
        package_checksum: @a,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => @a, "deps" => deps}
  end

  def entry(path, bytes),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => 33_188}

  # A pinned run's result.json: the build's lock is `lock`, its files `beams`.
  def result(name, pins, opts \\ []) do
    beams = Keyword.get(opts, :beams, ["beam-" <> name])

    build = %{
      "status" => Keyword.get(opts, :status, "pass"),
      "reason" => Keyword.get(opts, :reason),
      "elixir" => "1.20.5",
      "otp" => "28",
      "deps_lock" => Keyword.get(opts, :lock, Compatibility.Pins.to_lock(pins["deps"])),
      "package_checksum" => @a,
      "declared" => [],
      "manager" => "mix",
      "compile_env" => [],
      "compile_env_rule" => 1,
      "compile_inputs" => [],
      "built_priv" => [],
      "portability_rule" => 2,
      "judge_revision" => 29,
      "compile_observations" => Keyword.get(opts, :observations, %{}),
      "file_manifest" => %{
        "ebin" => Enum.with_index(beams, &entry("ebin/m#{&2}.beam", &1)),
        "priv" => []
      }
    }

    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-19T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "requested_optional_deps" => Keyword.get(opts, :echo, "pinned"),
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => "pinned"},
      "pins" => %{"hash" => Keyword.get(opts, :hash, pins["hash"]), "status" => "reproduced"},
      "toolchain_build" => build
    }
    |> then(&if(opts[:sibling], do: Map.put(&1, "deterministic_build", opts[:sibling]), else: &1))
  end

  def opts(name, pins, files_dir) do
    %{
      package: name,
      version: "1.0.0",
      pin_hash: pins["hash"],
      pins: pins,
      target: "pure_elixir",
      run_id: "pn-#{System.unique_integer([:positive])}",
      image_digest: "sha256:pn",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.20/28",
      builder_version: Portal.Toolchains.builder_version()
    }
  end

  def ingest(name, pins, opts \\ []) do
    beams = Keyword.get(opts, :beams, ["beam-" <> name])
    Ingestion.ingest_pinned(result(name, pins, opts), opts(name, pins, files(beams)))
  end

  def shas(row) do
    ArtifactMembership
    |> Ash.Query.filter(pinned_build_id == ^row.id)
    |> Ash.read!(domain: Catalog)
    |> Enum.map(& &1.sha256)
  end

  test "a reproduced set is stored as a pass with its files, never as a run or toolchain build" do
    name = unique()
    pins = pins(name)

    assert {:ok, %PinnedBuild{status: :pass} = row} = ingest(name, pins)
    assert row.pin_hash == pins["hash"]
    assert row.target == "pure_elixir" and row.system_version == ""
    assert row.deps_lock == Compatibility.Pins.to_lock(pins["deps"])
    assert row.pins == pins
    assert shas(row) == [sha("beam-" <> name)]

    assert Portal.Catalog.Run
           |> Ash.Query.filter(package.name == ^name)
           |> Ash.read!(domain: Catalog) == []

    assert Portal.Catalog.ToolchainBuild
           |> Ash.Query.filter(package.name == ^name)
           |> Ash.read!(domain: Catalog) == []
  end

  test "a lock that is not the set is a skipped row with no files" do
    name = unique()
    pins = pins(name)
    lock = %{"decimal" => %{"version" => "2.2.0", "checksum" => @b}}

    assert {:ok, %PinnedBuild{status: :skipped, reason: reason, file_manifest: nil} = row} =
             ingest(name, pins, lock: lock)

    assert reason == "pins not reproduced on the host: pins_closure_mismatch (~decimal)"
    assert shas(row) == []
  end

  test "a result echoing another set is skipped" do
    name = unique()

    assert {:ok, %PinnedBuild{status: :skipped, reason: "pins not reproduced: " <> _}} =
             ingest(name, pins(name), hash: @b)
  end

  test "a result that was not a pinned build is refused" do
    name = unique()

    assert {:error, {:identity_mismatch, %{variant: :pinned}, _}} =
             ingest(name, pins(name), echo: "include")
  end

  test "a transient could-not-judge never replaces a pass" do
    name = unique()
    pins = pins(name)
    assert {:ok, %PinnedBuild{status: :pass, id: id}} = ingest(name, pins)

    assert {:ok, %PinnedBuild{status: :pass, id: ^id, attempted_at: %DateTime{}}} =
             ingest(name, pins,
               status: "skipped",
               reason: Compatibility.Portability.could_not_judge(),
               observations: %{"trace_stats" => %{"transient" => true}}
             )
  end

  test "a failed compile is a fail verdict on a new key" do
    name = unique()

    assert {:ok, %PinnedBuild{status: :fail, reason: "compile failed: boom"}} =
             ingest(name, pins(name), status: "error", reason: "boom")
  end

  test "a sibling that holds is stored beside the pinned build" do
    name = unique()
    {normal, sibling} = Portal.PinnedIngestTest.Beams.pair(name)
    pins = pins(name)

    sibling_build = %{
      "status" => "pass",
      "erl_compiler_options" => ["deterministic"],
      "judge_revision" => 29,
      "file_manifest" => %{"ebin" => [entry("ebin/m0.beam", sibling)], "priv" => []}
    }

    result =
      result(name, pins,
        beams: [normal],
        sibling: Map.merge(result(name, pins)["toolchain_build"], sibling_build)
      )

    assert {:ok, row} =
             Ingestion.ingest_pinned(result, opts(name, pins, files([normal, sibling])))

    assert %DeterministicBuild{status: :pass, toolchain_build_id: nil} =
             DeterministicBuild
             |> Ash.Query.filter(pinned_build_id == ^row.id)
             |> Ash.read_one!(domain: Catalog)
  end
end

defmodule Portal.PinnedIngestTest.Beams do
  @moduledoc false
  # An Erlang module holding `?FILE`, compiled without and with the option.
  def pair(name) do
    dir = Path.join(System.tmp_dir!(), "pn-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "m0.erl")
    File.write!(path, "-module(m0).\n-export([f/0]).\nf() -> {?FILE, #{inspect(name)}}.\n")
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end
end
