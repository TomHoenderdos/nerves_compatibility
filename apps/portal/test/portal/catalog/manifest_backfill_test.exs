defmodule Portal.Catalog.ManifestBackfillTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{Ingestion, ManifestBackfill, SystemResult}
  alias Portal.Repo

  # Ingestion strips manifests on the way in, so a pre-change row cannot be
  # created through it. Write the column directly instead — that is exactly the
  # state the rows in production are already in.
  defp legacy_row(name, scans) do
    dir = Path.join(System.tmp_dir!(), "mb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        },
        %{run_id: "mb-#{name}", image_digest: "sha256:x", files_dir: dir}
      )

    system_result =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read_one!(domain: Portal.Catalog)

    Repo.query!(
      "UPDATE catalog_system_results SET dependency_scans = $1 WHERE id = $2",
      [scans, Ecto.UUID.dump!(system_result.id)]
    )

    system_result.id
  end

  defp scans_of(id) do
    %Postgrex.Result{rows: [[scans]]} =
      Repo.query!("SELECT dependency_scans FROM catalog_system_results WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    scans
  end

  defp with_manifest do
    %{
      "jason" => %{
        "flags" => ["nif"],
        "beam_count" => 3,
        "footprint" => %{
          "total_bytes" => 12_345,
          "file_manifest" => %{
            "ebin" => [%{"path" => "ebin/j.beam", "size" => 347, "sha256" => "abc"}],
            "priv" => []
          }
        }
      }
    }
  end

  test "removes the manifest and leaves everything else in place" do
    id = legacy_row("stripme", with_manifest())

    assert {:ok, %{rows: 1, dry_run: false}} = ManifestBackfill.run()

    scan = scans_of(id)["jason"]
    assert scan["flags"] == ["nif"]
    assert scan["beam_count"] == 3
    assert scan["footprint"]["total_bytes"] == 12_345
    refute Map.has_key?(scan["footprint"], "file_manifest")
  end

  test "is idempotent: a second pass finds nothing to do" do
    legacy_row("twice", with_manifest())

    assert {:ok, %{rows: 1}} = ManifestBackfill.run()
    assert {:ok, %{rows: 0, batches: 0}} = ManifestBackfill.run()
  end

  test "commits in batches rather than one statement" do
    for n <- 1..3, do: legacy_row("batch#{n}", with_manifest())

    assert {:ok, %{rows: 3, batches: 3}} = ManifestBackfill.run(batch_size: 1)
  end

  test "a dry run reports the work and changes nothing" do
    id = legacy_row("dry", with_manifest())

    assert {:ok, report} = ManifestBackfill.run(dry_run: true)
    assert report.dry_run
    assert report.rows == 1
    assert report.manifest_bytes > 0

    assert Map.has_key?(scans_of(id)["jason"]["footprint"], "file_manifest")
  end

  test "leaves alone a scan whose footprint has no manifest" do
    scans = %{"jason" => %{"flags" => [], "footprint" => %{"total_bytes" => 1}}}
    id = legacy_row("clean", scans)

    assert {:ok, %{rows: 0}} = ManifestBackfill.run()
    assert scans_of(id) == scans
  end

  test "leaves alone the error map the worker emits when the scan failed" do
    # The values here are arrays, not objects, so `->'footprint'` yields NULL
    # rather than raising and the row must not match the predicate.
    scans = %{"__errors__" => ["dependency beam scan failed: :enoent"]}
    id = legacy_row("errors", scans)

    assert {:ok, %{rows: 0}} = ManifestBackfill.run()
    assert scans_of(id) == scans
  end

  test "steps over a row whose dependency_scans is not an object" do
    # Ash types the attribute `:map`, so the app can only ever write an object
    # or NULL — but the column is plain jsonb and `jsonb_each` raises on an
    # array. The predicate's typecheck is what keeps one malformed row from
    # aborting the whole backfill, so it needs a row that would trip it.
    id = legacy_row("notanobject", ["nope"])

    assert {:ok, %{rows: 0}} = ManifestBackfill.run()
    assert scans_of(id) == ["nope"]
  end

  test "rewrites only the dependencies that carry a manifest" do
    scans =
      with_manifest()
      |> Map.put("plain", %{"flags" => [], "footprint" => %{"total_bytes" => 9}})
      |> Map.put("nofootprint", %{"beam_count" => 1})

    id = legacy_row("mixed", scans)

    assert {:ok, %{rows: 1}} = ManifestBackfill.run()

    after_run = scans_of(id)
    refute Map.has_key?(after_run["jason"]["footprint"], "file_manifest")
    assert after_run["plain"] == %{"flags" => [], "footprint" => %{"total_bytes" => 9}}
    assert after_run["nofootprint"] == %{"beam_count" => 1}
  end
end
