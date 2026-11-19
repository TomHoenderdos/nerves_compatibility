defmodule Portal.PinnedIngestTest do
  # Pinned builds (lock-driven builds spec, phase 1): ingested through the
  # toolchain build's own staging and gates into `catalog_pinned_builds`,
  # never as a run or a toolchain build, and stored as a pass only when the
  # lock they compiled against is exactly the set.
  use Portal.DataCase, async: false

  require Ash.Query

  import Portal.PinnedFixtures

  alias Portal.Catalog
  alias Portal.Catalog.{DeterministicBuild, Ingestion, PinnedBuild}

  @b String.duplicate("b", 64)

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
    {normal, sibling} = beam_pair(name)
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
