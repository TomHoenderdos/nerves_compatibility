defmodule Portal.Precompiled.FirmwareRefusalTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.SystemResult
  alias Portal.Precompiled.FirmwareRefusal

  require Ash.Query

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @refused %{
    "status" => "skipped",
    "reason" => "bakes the build path: Elixir.Fx \"<root>/deps_rpi4/fx/lib\"",
    "observations" => []
  }

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "fw-refusal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp manifest(bytes) do
    %{
      "ebin" => [
        %{
          "path" => "ebin/Elixir.Fx.beam",
          "sha256" => sha(bytes),
          "size" => byte_size(bytes),
          "mode" => 33_188
        }
      ],
      "priv" => []
    }
  end

  # A run of jason `version` finished at `at`. Its rpi4 target publishes
  # `bytes` (with `variant: true` also a "without" variant), or, with
  # `refused:`, carries that `build_root` and publishes nothing, as the
  # worker writes a withheld target. `scope: "targets"` makes it a partial
  # run of `systems:` only.
  defp run!(version, at, bytes, opts \\ []) do
    dir = tmp_dir()
    File.write!(Path.join(dir, sha(bytes)), bytes)
    fixture = @fixture |> File.read!() |> Jason.decode!()

    rpi4 =
      fixture
      |> get_in(["systems", "nerves_system_rpi4"])
      |> Map.put("compile_env", [])

    rpi4 =
      case Keyword.get(opts, :refused) do
        nil ->
          rpi4
          |> Map.put("beam_scan", %{"footprint" => %{"file_manifest" => manifest(bytes)}})
          |> Map.put("build_root", %{"status" => "pass", "reason" => nil, "observations" => []})

        build_root ->
          rpi4
          |> Map.put("beam_scan", %{"footprint" => %{}})
          |> Map.put("build_root", build_root)
      end

    rpi4 =
      case Keyword.fetch(opts, :judge) do
        {:ok, judge} ->
          rpi4
          |> Map.put("firmware_judge", judge)
          |> then(fn r ->
            if judge["status"] == "skipped",
              do: Map.put(r, "beam_scan", %{"footprint" => %{}}),
              else: r
          end)

        :error ->
          rpi4
      end

    rpi4 =
      if Keyword.get(opts, :variant, false) do
        Map.put(rpi4, "published_variants", [
          %{
            "variant" => "without",
            "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(bytes <> "w")}},
            "compile_env" => [],
            "deps_lock" => %{}
          }
        ])
      else
        rpi4
      end

    File.write!(Path.join(dir, sha(bytes <> "w")), bytes <> "w")

    systems =
      fixture["systems"]
      |> Map.put("nerves_system_rpi4", rpi4)
      |> Map.take(Keyword.get(opts, :systems, Map.keys(fixture["systems"])))

    result =
      fixture
      |> Map.merge(%{
        "run_id" => "fw-jason-#{version}-#{System.unique_integer([:positive])}",
        "package" => %{"name" => "jason", "version" => version},
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "finished_at" => at,
        "systems" => systems
      })
      |> then(fn r ->
        case Keyword.get(opts, :scope) do
          nil -> r
          scope -> Map.put(r, "scope", scope)
        end
      end)

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: "jason",
        version: version,
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "log"
      })

    run
  end

  defp served_rpi4(version) do
    case Catalog.precompiled_manifest_v2("jason") do
      nil ->
        []

      %{"versions" => versions} ->
        versions
        |> Map.get(version, %{})
        |> Map.get("builds", [])
        |> Enum.filter(&(&1["target"] == "nerves_system_rpi4"))
    end
  end

  defp served_v1?(version) do
    case Catalog.precompiled_manifest("jason") do
      nil -> false
      %{versions: versions} -> get_in(versions, [version, "nerves_system_rpi4"]) != nil
    end
  end

  defp rpi4_of(run) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
    |> Ash.read_one!(domain: Catalog)
  end

  test "a newer run's refusal withdraws an older run's build of the version and target" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    assert [_] = served_rpi4("1.4.0")
    assert served_v1?("1.4.0")

    new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)

    assert served_rpi4("1.4.0") == []
    refute served_v1?("1.4.0")

    withdrawn = rpi4_of(old)
    assert withdrawn.unpublished_at
    assert withdrawn.unpublished_reason == SystemResult.superseded_by_refusal()
    assert withdrawn.status == :pass

    refusal = rpi4_of(new)
    assert refusal.build_root["status"] == "skipped"
    assert refusal.status == :pass
    assert is_nil(refusal.unpublished_at)
  end

  test "a newer run's firmware judge refusal withdraws an older run's build of the version and target" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    assert [_] = served_rpi4("1.4.0")

    judge = %{
      "status" => "skipped",
      "reason" => "rebar3 build runs plugins",
      "classes" => ["plugins_hooks"]
    }

    new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", judge: judge)

    assert served_rpi4("1.4.0") == []
    assert rpi4_of(old).unpublished_reason == SystemResult.superseded_by_refusal()
    assert rpi4_of(new).firmware_judge == judge
  end

  test "a firmware judge pass or unjudged verdict withdraws nothing" do
    for status <- ["pass", "unjudged"] do
      version = "1.6.#{System.unique_integer([:positive])}"
      old = run!(version, "2026-11-01T10:00:00Z", "old-beam-" <> version)
      judge = %{"status" => status, "reason" => nil, "classes" => []}
      _ = run!(version, "2026-11-02T10:00:00Z", "new-beam-" <> version, judge: judge)

      assert is_nil(rpi4_of(old).unpublished_at), status
    end
  end

  test "another version's build is left alone" do
    other = run!("1.3.0", "2026-11-01T10:00:00Z", "other-beam")
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)

    assert is_nil(rpi4_of(other).unpublished_at)
    assert [_] = served_rpi4("1.3.0")
  end

  test "an older build ingested after the refusal is held back" do
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)
    late = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")

    assert rpi4_of(late).unpublished_reason == SystemResult.superseded_by_refusal()
    assert served_rpi4("1.4.0") == []
  end

  test "a passing build after the refusal is served; the older one stays withdrawn" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "mid-beam", refused: @refused)
    newest = run!("1.4.0", "2026-11-03T10:00:00Z", "new-beam")

    assert is_nil(rpi4_of(newest).unpublished_at)
    assert rpi4_of(old).unpublished_at
    assert [build] = served_rpi4("1.4.0")
    assert build["build"]["run_id"] == newest.run_id
  end

  test "a refusal in a revoked run withdraws nothing" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)

    Repo.query!(
      "UPDATE catalog_system_results SET unpublished_at = NULL, unpublished_reason = NULL"
    )

    Repo.query!(
      "UPDATE catalog_runs SET revoked_at = now() WHERE finished_at > '2026-11-01T12:00:00Z'"
    )

    assert FirmwareRefusal.withdraw_superseded() == 0
    assert is_nil(rpi4_of(old).unpublished_at)
  end

  test "carried copies of an older build are withdrawn, and a carried refusal keeps its build_root" do
    _full = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")

    # A partial run of host only carries rpi4 (and its files) from the full run.
    partial =
      run!("1.4.0", "2026-11-01T12:00:00Z", "unused", scope: "targets", systems: ["host"])

    carried = rpi4_of(partial)
    assert carried.carried_from_run_id
    assert is_nil(carried.unpublished_at)

    # A partial run of rpi4 refuses it.
    refusal =
      run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam",
        scope: "targets",
        systems: ["nerves_system_rpi4"],
        refused: @refused
      )

    assert rpi4_of(partial).unpublished_reason == SystemResult.superseded_by_refusal()
    assert served_rpi4("1.4.0") == []

    # A later partial run carries the refusal along, build_root and all.
    later =
      run!("1.4.0", "2026-11-03T10:00:00Z", "unused", scope: "targets", systems: ["host"])

    copy = rpi4_of(later)
    assert copy.carried_from_run_id == refusal.id
    assert copy.build_root == rpi4_of(refusal).build_root
    assert served_rpi4("1.4.0") == []
  end

  test "a newer refusal of a target's variant withdraws an older build with that variant" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam", variant: true)
    assert [%{"variant" => "without"}] = rpi4_of(old).published_variants

    variant_refused =
      Map.merge(%{"status" => "pass", "reason" => nil, "observations" => []}, %{
        "variants" => %{"without" => %{"status" => "skipped", "reason" => "bakes the build path"}}
      })

    newer = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: variant_refused)

    assert rpi4_of(old).unpublished_reason == SystemResult.superseded_by_refusal()
    assert is_nil(rpi4_of(newer).unpublished_at)
  end

  test "undoing a build path withdrawal does not put back a build a newer refusal supersedes" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    at = ~U[2026-11-01 12:00:00.000000Z]

    Repo.query!(
      "UPDATE catalog_system_results SET unpublished_at = $1, unpublished_reason = $2 WHERE id = $3",
      [at, SystemResult.baked_build_path(), Ecto.UUID.dump!(rpi4_of(old).id)]
    )

    # The refusal finds the older build already withdrawn and leaves it be.
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)
    assert rpi4_of(old).unpublished_reason == SystemResult.baked_build_path()

    assert {:restored, 0} = Portal.Precompiled.FirmwareBuildPathWithdrawal.undo(at)

    assert rpi4_of(old).unpublished_reason == SystemResult.superseded_by_refusal()
    assert served_rpi4("1.4.0") == []
    refute served_v1?("1.4.0")
  end

  test "an operator sweep withdraws what a release without the rule left served, idempotently" do
    old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
    _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", refused: @refused)

    Repo.query!(
      "UPDATE catalog_system_results SET unpublished_at = NULL, unpublished_reason = NULL"
    )

    assert served_rpi4("1.4.0") != [] or served_v1?("1.4.0")

    assert FirmwareRefusal.withdraw_superseded() == 1
    assert FirmwareRefusal.withdraw_superseded() == 0
    assert rpi4_of(old).unpublished_reason == SystemResult.superseded_by_refusal()
  end
end
