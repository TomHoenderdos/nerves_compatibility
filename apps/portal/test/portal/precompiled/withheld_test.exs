defmodule Portal.Precompiled.WithheldTest do
  # Changes application env and ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Precompiled.Withheld

  require Ash.Query

  import Portal.PrecompiledFixtures

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @run_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
  @decimal %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @liveview Map.put(@decimal, "phoenix_live_view", %{"version" => "1.1.0", "checksum" => "def"})

  # A full run with every key format 2 needs, its rpi4 result publishing one
  # file (`@run_sha`).
  defp run(deps_lock, system_deps_lock \\ nil) do
    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("deps_lock", deps_lock)
      |> Map.put("package_checksum", "outer")
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

    if system_deps_lock,
      do: put_in(result, ["systems", "nerves_system_rpi4", "deps_lock"], system_deps_lock),
      else: result
  end

  defp toolchain_sha(build), do: hd(build.file_manifest["ebin"])["sha256"]

  defp put_withheld(value) do
    old = Application.get_env(:portal, Withheld)
    on_exit(fn -> restore(old) end)
    Application.put_env(:portal, Withheld, value)
  end

  defp restore(nil), do: Application.delete_env(:portal, Withheld)
  defp restore(old), do: Application.put_env(:portal, Withheld, old)

  describe "packages/0" do
    test "defaults to phoenix_live_view" do
      put_withheld(nil)
      assert Withheld.packages() == ["phoenix_live_view"]
    end

    test "reads the configured list" do
      put_withheld(packages: ["b", "a"])
      assert Withheld.packages() == ["a", "b"]

      put_withheld(packages: [])
      assert Withheld.packages() == []
    end

    test "a malformed list falls back to the default" do
      put_withheld(packages: [:phoenix_live_view])
      assert Withheld.packages() == ["phoenix_live_view"]

      put_withheld(packages: "phoenix_live_view")
      assert Withheld.packages() == ["phoenix_live_view"]
    end
  end

  test "withheld?/3 matches the package itself or any locked dependency" do
    assert Withheld.withheld?("phoenix_live_view", @decimal, ["phoenix_live_view"])
    assert Withheld.withheld?("x", @liveview, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @decimal, ["phoenix_live_view"])
    refute Withheld.withheld?("x", %{}, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @liveview, [])
  end

  # A build with no recorded lock (format 1's `"deps": null`) has an unknown
  # closure: fail closed while anything is withheld at all.
  test "withheld?/3 withholds an unknown closure unless nothing is withheld" do
    assert Withheld.withheld?("x", nil, ["phoenix_live_view"])
    refute Withheld.withheld?("x", nil, [])
  end

  describe "a full run without a recorded lock" do
    test "is in no manifest and its file is not served" do
      ingest_with_artifact(run(nil))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "is published when nothing is withheld" do
      put_withheld(packages: [])
      ingest_with_artifact(run(nil))

      assert %{versions: %{"1.4.1" => %{"nerves_system_rpi4" => _}}} =
               Catalog.precompiled_manifest("jason")

      assert "jason" in Catalog.packages_with_precompiled_files()
      assert Catalog.published_sha256?(@run_sha)
    end
  end

  test "a toolchain build without a recorded lock is withheld" do
    name = "tc_nolock_#{System.unique_integer([:positive])}"
    build = ingest_toolchain_build(name, "0.1.0", deps_lock: nil)

    assert Catalog.precompiled_manifest_v2(name) == nil
    refute name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(toolchain_sha(build))
  end

  describe "a full run's system result" do
    test "whose run lock has phoenix_live_view is in no manifest and its file is not served" do
      ingest_with_artifact(run(@liveview))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      assert %{v1: nil, v2: nil} = Catalog.precompiled_manifests("jason")
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "whose own system lock has phoenix_live_view is withheld too" do
      ingest_with_artifact(run(@decimal, @liveview))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "without phoenix_live_view is published in both formats" do
      ingest_with_artifact(run(@decimal))

      assert %{versions: %{"1.4.1" => %{"nerves_system_rpi4" => _}}} =
               Catalog.precompiled_manifest("jason")

      assert %{"versions" => %{"1.4.1" => %{"builds" => [_]}}} =
               Catalog.precompiled_manifest_v2("jason")

      assert "jason" in Catalog.packages_with_precompiled_files()
      assert Catalog.published_sha256?(@run_sha)
    end

    test "follows the configured list" do
      put_withheld(packages: [])
      ingest_with_artifact(run(@liveview))

      assert Catalog.precompiled_manifest("jason")
      assert Catalog.precompiled_manifest_v2("jason")
      assert Catalog.published_sha256?(@run_sha)

      put_withheld(packages: ["decimal"])
      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end
  end

  describe "a toolchain build" do
    test "whose lock has phoenix_live_view is withheld; one without is published" do
      withheld = "tc_lv_#{System.unique_integer([:positive])}"
      kept = "tc_ok_#{System.unique_integer([:positive])}"
      withheld_build = ingest_toolchain_build(withheld, "0.1.0", deps_lock: @liveview)
      kept_build = ingest_toolchain_build(kept, "0.1.0", deps_lock: @decimal)

      assert Catalog.precompiled_manifest_v2(withheld) == nil
      assert %{v2: nil} = Catalog.precompiled_manifests(withheld)
      refute withheld in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(withheld_build))

      assert %{"versions" => %{"0.1.0" => %{"builds" => [_]}}} =
               Catalog.precompiled_manifest_v2(kept)

      assert kept in Catalog.packages_with_precompiled_files()
      assert Catalog.published_sha256?(toolchain_sha(kept_build))
    end

    test "of phoenix_live_view itself is withheld" do
      build = ingest_toolchain_build("phoenix_live_view", "1.1.0", deps_lock: @decimal)

      assert Catalog.precompiled_manifest_v2("phoenix_live_view") == nil
      refute "phoenix_live_view" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(build))
    end

    test "follows the configured list" do
      name = "tc_cfg_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: @decimal)
      assert Catalog.precompiled_manifest_v2(name)

      put_withheld(packages: ["decimal"])
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute name in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(build))
    end
  end

  defp withdraw!(system_pkg) do
    Portal.Catalog.SystemResult
    |> Ash.Query.filter(system_pkg == ^system_pkg)
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.each(fn result ->
      result
      |> Ash.Changeset.for_update(:withdraw_publication, %{})
      |> Ash.update!(domain: Portal.Catalog)
    end)
  end

  describe "a withdrawn system result (unpublished_at)" do
    test "is in no manifest, does not list its package and its file is not served" do
      ingest_with_artifact(run(@decimal))
      before = Catalog.precompiled_fingerprints()["jason"]
      withdraw!("nerves_system_rpi4")

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      assert %{v1: nil, v2: nil} = Catalog.precompiled_manifests("jason")
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
      assert Catalog.precompiled_fingerprints()["jason"] != before
    end

    test "is withheld even when nothing else is" do
      put_withheld(packages: [])
      ingest_with_artifact(run(@decimal))
      withdraw!("nerves_system_rpi4")

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end

    test "stays withdrawn when a partial run carries it" do
      ingest_with_artifact(run(@decimal))
      withdraw!("nerves_system_rpi4")

      partial =
        @decimal
        |> run()
        |> Map.merge(%{
          "run_id" => "fixture-jason-targets",
          "scope" => "targets",
          "finished_at" => "2030-01-01T00:00:00Z"
        })
        |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))

      ingest_with_artifact(partial)

      carried =
        Portal.Catalog.SystemResult
        |> Ash.Query.filter(
          system_pkg == "nerves_system_rpi4" and not is_nil(carried_from_run_id)
        )
        |> Ash.read!(domain: Portal.Catalog)

      assert [%{unpublished_at: %DateTime{}}] = carried
      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute Catalog.published_sha256?(@run_sha)
    end

    # The withdrawal only narrows the withheld rule. A result
    # without a recorded lock that nobody withdrew is still an unknown
    # closure and withheld, exactly as before.
    test "leaves a lockless result withheld" do
      ingest_with_artifact(run(nil))

      assert Catalog.precompiled_manifest("jason") == nil
      assert Catalog.precompiled_manifest_v2("jason") == nil
      refute "jason" in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(@run_sha)
    end
  end

  # A batch reuses a package's manifests while its fingerprint is unchanged,
  # so a change to the list has to change every fingerprint.
  test "the list is part of every precompiled fingerprint" do
    name = "tc_fp_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.1.0", deps_lock: @decimal)
    before = Catalog.precompiled_fingerprints()[name]

    put_withheld(packages: ["decimal"])
    assert Catalog.precompiled_fingerprints()[name] != before
  end

  defp revoke!(build) do
    build |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
  end

  defp reload(build), do: Ash.get!(Catalog.ToolchainBuild, build.id, domain: Catalog)

  defp marked_build!(name) do
    build = name |> ingest_toolchain_build("0.1.0", deps_lock: @liveview) |> revoke!()
    assert %{marked: [_]} = Catalog.mark_withheld_revoked([build.id], dry_run: false)
    build
  end

  describe "toolchain builds revoked for their withheld closure" do
    test "are marked only when revoked, unmarked by R5 and withheld; dry run by default" do
      lv = "tc_rev_lv_#{System.unique_integer([:positive])}"
      ok = "tc_rev_ok_#{System.unique_integer([:positive])}"
      lv_build = lv |> ingest_toolchain_build("0.1.0", deps_lock: @liveview) |> revoke!()
      ok_build = ok |> ingest_toolchain_build("0.1.0", deps_lock: @decimal) |> revoke!()

      live =
        ingest_toolchain_build("tc_live_#{System.unique_integer([:positive])}", "0.1.0",
          deps_lock: @liveview
        )

      ids = [lv_build.id, ok_build.id, live.id, Ecto.UUID.generate()]

      assert %{marked: [id], skipped: skipped} = Catalog.mark_withheld_revoked(ids)
      assert id == lv_build.id
      assert reload(lv_build).revoked_reason == nil

      assert Enum.sort(Enum.map(skipped, &elem(&1, 1))) ==
               ["closure has no withheld package", "no such toolchain build", "not revoked"]

      assert %{marked: [_]} = Catalog.mark_withheld_revoked(ids, dry_run: false)
      assert reload(lv_build).revoked_reason == "withheld closure"
    end

    test "a dry run writes nothing" do
      build =
        "tc_dry_#{System.unique_integer([:positive])}"
        |> ingest_toolchain_build("0.1.0", deps_lock: @liveview)
        |> revoke!()

      before = reload(build)

      assert %{marked: [_], skipped: []} =
               Catalog.mark_withheld_revoked([build.id], dry_run: true)

      assert reload(build) == before
    end

    test "skips a row that already records its config reads and an id that is no uuid" do
      build =
        "tc_r5_#{System.unique_integer([:positive])}"
        |> ingest_toolchain_build("0.1.0", deps_lock: @liveview, compile_env_rule: 1)
        |> revoke!()

      assert %{marked: [], skipped: skipped} =
               Catalog.mark_withheld_revoked([build.id, "not-a-uuid"], dry_run: false)

      assert skipped == [
               {build.id, "already records its config reads"},
               {"not-a-uuid", "no such toolchain build"}
             ]

      assert reload(build).revoked_reason == nil
    end

    test "a marked row's rebuild with R5 un-revokes it; one without stays revoked" do
      name = "tc_rebuild_#{System.unique_integer([:positive])}"
      build = marked_build!(name)

      ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview)
      assert %DateTime{} = reload(build).revoked_at

      ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)
      rebuilt = reload(build)

      assert {rebuilt.revoked_at, rebuilt.revoked_reason, rebuilt.compile_env_rule} ==
               {nil, nil, 1}

      assert rebuilt.transient_attempts == 0
    end

    test "a marked row's failed rebuild with the rule stays revoked and marked" do
      name = "tc_rebuild_fail_#{System.unique_integer([:positive])}"
      build = marked_build!(name)

      ingest_toolchain_build(name, "0.1.0",
        deps_lock: @liveview,
        compile_env_rule: 1,
        status: "error"
      )

      rebuilt = reload(build)
      assert rebuilt.status == :fail
      assert %DateTime{} = rebuilt.revoked_at
      assert rebuilt.revoked_reason == "withheld closure"
    end

    test "an un-revoked LiveView-closure row is still withheld from publication" do
      name = "tc_unrevoked_lv_#{System.unique_integer([:positive])}"
      marked_build!(name)

      rebuilt =
        ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)

      assert reload(rebuilt).revoked_at == nil
      assert Catalog.precompiled_manifest(name) == nil
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute name in Catalog.packages_with_precompiled_files()
      refute Catalog.published_sha256?(toolchain_sha(rebuilt))
    end

    test "never overwrites another revocation reason" do
      build =
        "tc_other_mark_#{System.unique_integer([:positive])}"
        |> ingest_toolchain_build("0.1.0", deps_lock: @liveview)
        |> revoke!()

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET revoked_reason = 'leaked secret' WHERE id = $1",
        [Ecto.UUID.dump!(build.id)]
      )

      assert %{marked: [], skipped: [{_, "revoked for another reason: leaked secret"}]} =
               Catalog.mark_withheld_revoked([build.id], dry_run: false)

      assert reload(build).revoked_reason == "leaked secret"
    end

    test "a marked row's rebuild with the rule but no compile_env stays revoked" do
      name = "tc_rebuild_nil_#{System.unique_integer([:positive])}"
      build = marked_build!(name)

      ingest_toolchain_build(name, "0.1.0",
        deps_lock: @liveview,
        compile_env_rule: 1,
        compile_env: nil
      )

      rebuilt = reload(build)
      assert %DateTime{} = rebuilt.revoked_at
      assert rebuilt.revoked_reason == "withheld closure"
    end

    test "an unmarked revoked row stays revoked whatever its rebuild records" do
      name = "tc_plain_rev_#{System.unique_integer([:positive])}"
      build = name |> ingest_toolchain_build("0.1.0", deps_lock: @liveview) |> revoke!()
      ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)
      assert %DateTime{} = reload(build).revoked_at
    end

    test "a row revoked for another reason is never un-revoked" do
      name = "tc_other_rev_#{System.unique_integer([:positive])}"
      build = name |> ingest_toolchain_build("0.1.0", deps_lock: @liveview) |> revoke!()

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET revoked_reason = 'leaked secret' WHERE id = $1",
        [Ecto.UUID.dump!(build.id)]
      )

      ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)
      rebuilt = reload(build)
      assert %DateTime{} = rebuilt.revoked_at
      assert rebuilt.revoked_reason == "leaked secret"
    end

    test "the un-revoke rolls back with the row write it belongs to" do
      name = "tc_rollback_#{System.unique_integer([:positive])}"
      build = marked_build!(name)

      # Rejecting the membership insert fails the ingest after the row write
      # and the un-revoke ran; neither may survive it.
      Portal.Repo.query!("""
      CREATE FUNCTION ncc_test_reject_membership() RETURNS trigger LANGUAGE plpgsql AS
      $$ BEGIN RAISE EXCEPTION 'rejected'; END $$
      """)

      Portal.Repo.query!("""
      CREATE TRIGGER ncc_test_reject_membership BEFORE INSERT ON catalog_artifact_memberships
      FOR EACH ROW EXECUTE FUNCTION ncc_test_reject_membership()
      """)

      failed =
        try do
          ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)
        rescue
          _ -> :failed
        end

      assert failed == :failed
      kept = reload(build)
      assert %DateTime{} = kept.revoked_at
      assert {kept.revoked_reason, kept.compile_env_rule} == {"withheld closure", nil}
    end
  end
end
