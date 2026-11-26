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

  # A pinned build is no run: it never writes the package's latest version
  # (`Portal.Catalog.LatestRun`), not even for a package the catalog does
  # not hold yet, which it creates bare, as a host-native ingest does.
  test "a package the catalog does not hold is created without a latest version" do
    name = unique()
    pins = pins(name)
    result = put_in(result(name, pins), ["package", "description"], "from the lock")

    assert {:ok, %PinnedBuild{status: :pass}} =
             Ingestion.ingest_pinned(result, opts(name, pins, files(["beam-" <> name])))

    assert %Portal.Catalog.Package{latest_version: nil, description: nil, last_run_at: nil} =
             package(name)
  end

  test "a package's latest version stays what its runs made it" do
    name = unique()

    Portal.Catalog.Package
    |> Ash.Changeset.for_create(:create, %{name: name, latest_version: "2.0.0"})
    |> Ash.create!(domain: Catalog)

    assert {:ok, %PinnedBuild{status: :pass}} = ingest(name, pins(name))
    assert %Portal.Catalog.Package{latest_version: "2.0.0"} = package(name)
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

  # S9 re-review R1-2, as S1 for toolchain rows: a transient from a failed
  # declared fetch (`trace_stats.declared_unknown`) is today's judge
  # refusing a probe it could not place, so the served pinned pass is
  # withdrawn at once, not kept for the retries; a retry that passes
  # serves again.
  test "a transient from a failed declared fetch withdraws a served pass; a pass serves again" do
    name = unique()
    pins = pins(name)
    assert {:ok, %PinnedBuild{status: :pass, id: id} = passed} = ingest(name, pins)
    assert shas(passed) == [sha("beam-" <> name)]

    assert {:ok, %PinnedBuild{id: ^id, status: :error} = withdrawn} =
             ingest(name, pins,
               status: "skipped",
               reason: Compatibility.Portability.could_not_judge(),
               observations: %{
                 "trace_stats" => %{"transient" => true, "declared_unknown" => ["plug_cowboy"]}
               }
             )

    assert shas(withdrawn) == []

    assert {:ok, %PinnedBuild{id: ^id, status: :pass} = again} = ingest(name, pins)
    assert shas(again) == [sha("beam-" <> name)]
  end

  test "a could-not-judge names its cause" do
    name = unique()

    assert {:ok, %PinnedBuild{status: :skipped, reason: reason}} =
             ingest(name, pins(name),
               status: "skipped",
               reason: Compatibility.Portability.could_not_judge(),
               observations: %{
                 "trace_stats" => %{"transient" => false},
                 "problems" => ["no end line", "trace collector died: killed"]
               }
             )

    assert reason == "portability could not be judged (trace collector died: killed)"
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

    assert row.sibling_attempted
  end

  # `Portal.Pins.from_lock/2`'s `deterministic: true` builds a served pass
  # again for its sibling only while its row records no attempt.
  test "a run that tried for a sibling records the attempt, held or not; one that did not, none" do
    name = unique()
    pins = pins(name)
    assert {:ok, %PinnedBuild{status: :pass, sibling_attempted: false}} = ingest(name, pins)

    refused = %{"status" => "skipped", "reason" => "its compile failed"}

    assert {:ok, %PinnedBuild{status: :pass, sibling_attempted: true} = row} =
             ingest(name, pins, sibling: refused)

    assert DeterministicBuild
           |> Ash.Query.filter(pinned_build_id == ^row.id)
           |> Ash.read!(domain: Catalog) == []

    # A rebuild that was not asked for one never lowers it.
    assert {:ok, %PinnedBuild{id: id, sibling_attempted: true}} = ingest(name, pins)
    assert id == row.id
  end

  # `Portal.Pins.from_lock/2` sets it when it queues a sibling backfill; no
  # write of the row lowers it again, an older release's included.
  test "no upsert lowers the recorded attempt" do
    name = unique()
    pins = pins(name)
    assert {:ok, %PinnedBuild{sibling_attempted: false} = row} = ingest(name, pins)

    attrs =
      row
      |> Map.take(PinnedBuild.identity() ++ [:pins, :status])
      |> Map.put(:sibling_attempted, true)

    upsert =
      &(PinnedBuild |> Ash.Changeset.for_create(:upsert, &1) |> Ash.create!(domain: Catalog))

    assert %PinnedBuild{id: id, sibling_attempted: true} = upsert.(attrs)
    assert id == row.id
    assert %PinnedBuild{sibling_attempted: true} = upsert.(%{attrs | sibling_attempted: false})
    assert %PinnedBuild{sibling_attempted: true} = upsert.(Map.delete(attrs, :sibling_attempted))
    assert Ash.get!(PinnedBuild, id, domain: Catalog).sibling_attempted
  end

  defp package(name) do
    Portal.Catalog.Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
  end
end
