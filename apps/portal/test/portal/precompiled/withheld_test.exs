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

  test "withheld? matches the package itself or any locked dependency" do
    assert Withheld.withheld?("phoenix_live_view", @decimal, ["phoenix_live_view"])
    assert Withheld.withheld?("x", @liveview, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @decimal, ["phoenix_live_view"])
    refute Withheld.withheld?("x", %{}, ["phoenix_live_view"])
    refute Withheld.withheld?("x", @liveview, [])
  end

  # A build with no recorded lock (format 1's `"deps": null`) has an unknown
  # closure: fail closed while anything is withheld at all.
  test "withheld? withholds an unknown closure unless nothing is withheld" do
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

    test "an un-revoked LiveView-closure row is published again" do
      name = "tc_unrevoked_lv_#{System.unique_integer([:positive])}"
      marked_build!(name)

      rebuilt =
        ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)

      assert reload(rebuilt).revoked_at == nil
      assert_toolchain_served(name, toolchain_sha(rebuilt))
    end

    test "marks a rule-1 row whose compile_env is null: it does not record its config reads" do
      build =
        "tc_null_env_#{System.unique_integer([:positive])}"
        |> ingest_toolchain_build("0.1.0", deps_lock: @liveview, compile_env_rule: 1)
        |> revoke!()

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET compile_env = NULL WHERE id = $1",
        [Ecto.UUID.dump!(build.id)]
      )

      assert %{compile_env_rule: 1, compile_env: nil} = reload(build)

      assert %{marked: [id], skipped: []} =
               Catalog.mark_withheld_revoked([build.id], dry_run: false)

      assert id == build.id
      assert reload(build).revoked_reason == "withheld closure"
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

  # The fixture's jason run with its one published file (`@run_sha`) on a
  # `pure_elixir` result, the only run result a build marks with its config
  # reads, instead of on the rpi4 firmware result.
  defp pure_run(deps_lock, rule) do
    result = run(deps_lock)
    pure = Map.put(result["systems"]["nerves_system_rpi4"], "compile_env_rule", rule)

    Map.update!(result, "systems", fn systems ->
      systems |> Map.delete("nerves_system_rpi4") |> Map.put("pure_elixir", pure)
    end)
  end

  defp r5(env \\ []), do: %{compile_env_rule: 1, compile_env: env}

  defp results(system_pkg) do
    Portal.Catalog.SystemResult
    |> Ash.Query.filter(system_pkg == ^system_pkg)
    |> Ash.read!(domain: Portal.Catalog)
  end

  defp restore_run_blob! do
    source = Path.join(System.tmp_dir!(), "withheld-blob-#{System.unique_integer([:positive])}")
    File.write!(source, "precompiled-beam")
    on_exit(fn -> File.rm(source) end)
    assert {:ok, _} = Portal.ArtifactStore.put(@run_sha, source)
  end

  defp sql!(sql, ids), do: Portal.Repo.query!(sql, [Enum.map(ids, &Ecto.UUID.dump!/1)])

  defp assert_run_served(name, sha) do
    assert %{versions: %{"1.4.1" => %{"pure_elixir" => _}}} = Catalog.precompiled_manifest(name)

    assert %{"versions" => %{"1.4.1" => %{"builds" => [%{"target" => "pure_elixir"}]}}} =
             Catalog.precompiled_manifest_v2(name)

    assert %{v1: %{}, v2: %{}} = Catalog.precompiled_manifests(name)
    assert name in Catalog.packages_with_precompiled_files()
    assert Catalog.published_sha256?(sha)
  end

  defp assert_toolchain_served(name, sha) do
    assert %{"versions" => %{"0.1.0" => %{"builds" => [_]}}} =
             Catalog.precompiled_manifest_v2(name)

    assert %{v2: %{}} = Catalog.precompiled_manifests(name)
    assert name in Catalog.packages_with_precompiled_files()
    assert Catalog.published_sha256?(sha)
  end

  defp assert_withheld(name, sha) do
    assert Catalog.precompiled_manifest(name) == nil
    assert Catalog.precompiled_manifest_v2(name) == nil
    assert %{v1: nil, v2: nil} = Catalog.precompiled_manifests(name)
    refute name in Catalog.packages_with_precompiled_files()
    refute Catalog.published_sha256?(sha)
  end

  describe "a build that records its config reads (R5)" do
    test "withheld?/4 lifts only the closure check, and only for rule 1 with a compile_env" do
      pkgs = ["phoenix_live_view"]

      refute Withheld.withheld?("x", @liveview, pkgs, r5())
      refute Withheld.withheld?("x", @liveview, pkgs, r5([%{"app" => "a"}]))
      refute Withheld.withheld?("phoenix_live_view", @decimal, pkgs, r5())

      # No lock: an unknown closure, which the mark does not vouch for.
      assert Withheld.withheld?("x", nil, pkgs, r5())
      assert Withheld.withheld?("phoenix_live_view", nil, pkgs, r5())

      # Anything but rule 1 next to a compile_env list.
      assert Withheld.withheld?("x", @liveview, pkgs, nil)
      assert Withheld.withheld?("x", @liveview, pkgs, %{compile_env_rule: 1, compile_env: nil})
      assert Withheld.withheld?("x", @liveview, pkgs, %{compile_env_rule: 2, compile_env: []})
      assert Withheld.withheld?("x", @liveview, pkgs, %{compile_env_rule: nil, compile_env: []})
      assert Withheld.withheld?("x", @liveview, pkgs, %{compile_env: []})

      # A run result counts only as `pure_elixir`: firmware results never
      # record their config reads.
      assert Withheld.withheld?("x", @liveview, pkgs, Map.put(r5(), :system_pkg, "rpi4"))
      refute Withheld.withheld?("x", @liveview, pkgs, Map.put(r5(), :system_pkg, "pure_elixir"))

      # Unmarked builds are judged as before.
      refute Withheld.withheld?("x", @decimal, pkgs, nil)
      refute Withheld.withheld?("x", nil, [], nil)
    end

    test "a toolchain build with phoenix_live_view in its lock is served" do
      name = "tc_r5_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)

      assert build.compile_env_rule == 1
      assert_toolchain_served(name, toolchain_sha(build))
    end

    test "a toolchain build of phoenix_live_view itself is served" do
      build =
        ingest_toolchain_build("phoenix_live_view", "0.1.0",
          deps_lock: @decimal,
          compile_env_rule: 1
        )

      assert_toolchain_served("phoenix_live_view", toolchain_sha(build))
    end

    test "a pure_elixir result with phoenix_live_view in its lock is served in both formats" do
      ingest_with_artifact(pure_run(@liveview, 1))

      assert [%{compile_env_rule: 1}] = results("pure_elixir")
      assert_run_served("jason", @run_sha)
    end

    test "a pure_elixir result whose own system lock has phoenix_live_view is served" do
      @decimal
      |> pure_run(1)
      |> put_in(["systems", "pure_elixir", "deps_lock"], @liveview)
      |> ingest_with_artifact()

      assert_run_served("jason", @run_sha)
    end

    test "a carried pure_elixir result keeps its rule and is served on its own" do
      ingest_with_artifact(pure_run(@liveview, 1))

      partial =
        @liveview
        |> pure_run(1)
        |> Map.merge(%{
          "run_id" => "fixture-jason-targets-r5",
          "scope" => "targets",
          "finished_at" => "2030-01-01T00:00:00Z"
        })
        |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))

      ingest_with_artifact(partial)
      # The fixture clears the blob before each ingest; the partial run
      # stages no file of its own, so put the carried result's back.
      restore_run_blob!()

      assert [%{compile_env_rule: 1} = carried] =
               Enum.filter(results("pure_elixir"), & &1.carried_from_run_id)

      # Withdraw the original row only, so the carried copy alone publishes.
      [original] = Enum.reject(results("pure_elixir"), & &1.carried_from_run_id)

      sql!(
        "UPDATE catalog_system_results SET unpublished_at = now() WHERE id = ANY($1)",
        [original.id]
      )

      assert carried.unpublished_at == nil
      assert_run_served("jason", @run_sha)
    end

    test "a firmware result's rule is not stored, and one forced on it does not exempt" do
      ingest_with_artifact(
        put_in(run(@liveview), ["systems", "nerves_system_rpi4", "compile_env_rule"], 1)
      )

      assert [%{compile_env_rule: nil}] = results("nerves_system_rpi4")
      assert_withheld("jason", @run_sha)

      # A row written before ingest dropped it, carried forward as well.
      sql!(
        "UPDATE catalog_system_results SET compile_env_rule = 1 WHERE id = ANY($1)",
        Enum.map(results("nerves_system_rpi4"), & &1.id)
      )

      assert_withheld("jason", @run_sha)

      partial =
        @liveview
        |> run()
        |> Map.merge(%{
          "run_id" => "fixture-jason-targets-fw",
          "scope" => "targets",
          "finished_at" => "2030-01-01T00:00:00Z"
        })
        |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))

      ingest_with_artifact(partial)
      restore_run_blob!()

      assert [%{compile_env_rule: 1}, %{compile_env_rule: 1}] = results("nerves_system_rpi4")
      assert_withheld("jason", @run_sha)
    end

    # The carried copy has no lock of its own, and the carrying run's lock has
    # no LiveView: only the source run's lock puts LiveView in its closure.
    defp carry_lockless_pure!(rule) do
      ingest_with_artifact(pure_run(@liveview, rule))

      partial =
        @decimal
        |> pure_run(rule)
        |> Map.merge(%{
          "run_id" => "fixture-jason-targets-lockless-#{rule}",
          "scope" => "targets",
          "finished_at" => "2030-01-01T00:00:00Z"
        })
        |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))

      ingest_with_artifact(partial)
      restore_run_blob!()

      [original] = Enum.reject(results("pure_elixir"), & &1.carried_from_run_id)
      [carried] = Enum.filter(results("pure_elixir"), & &1.carried_from_run_id)
      assert {carried.deps_lock, carried.compile_env_rule} == {nil, rule}

      sql!(
        "UPDATE catalog_system_results SET unpublished_at = now() WHERE id = ANY($1)",
        [original.id]
      )
    end

    test "a carried lockless pure_elixir result takes the source run's lock: rule 1 exempts it" do
      carry_lockless_pure!(1)
      assert_run_served("jason", @run_sha)
    end

    test "a carried lockless pure_elixir result takes the source run's lock: no rule, withheld" do
      carry_lockless_pure!(nil)
      assert_withheld("jason", @run_sha)
    end

    test "rule 1 with a null compile_env stays withheld" do
      ingest_with_artifact(pure_run(@liveview, 1))
      name = "tc_r5_nil_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 1)

      # Ingest never stores this pair; the selectors must not trust it anyway.
      sql!("UPDATE catalog_toolchain_builds SET compile_env = NULL WHERE id = ANY($1)", [
        build.id
      ])

      sql!(
        "UPDATE catalog_system_results SET compile_env = NULL WHERE id = ANY($1)",
        Enum.map(results("pure_elixir"), & &1.id)
      )

      assert %{compile_env_rule: 1, compile_env: nil} = reload(build)
      assert [%{compile_env_rule: 1, compile_env: nil}] = results("pure_elixir")
      assert_withheld(name, toolchain_sha(build))
      assert_withheld("jason", @run_sha)
    end

    test "a mark on a build without a valid compile_env is not kept, so it stays withheld" do
      name = "tc_r5_bad_#{System.unique_integer([:positive])}"

      build =
        ingest_toolchain_build(name, "0.1.0",
          deps_lock: @liveview,
          compile_env_rule: 1,
          compile_env: [%{"app" => 1}]
        )

      assert build.compile_env_rule == nil
      assert_withheld(name, toolchain_sha(build))
    end

    test "rule 2 stays withheld" do
      ingest_with_artifact(pure_run(@liveview, 2))
      name = "tc_r5_two_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: @liveview, compile_env_rule: 2)

      assert build.compile_env_rule == 2
      assert [%{compile_env_rule: 2}] = results("pure_elixir")
      assert_withheld(name, toolchain_sha(build))
      assert_withheld("jason", @run_sha)
    end

    test "no recorded lock with rule 1 stays withheld" do
      ingest_with_artifact(pure_run(nil, 1))
      name = "tc_r5_nolock_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: nil, compile_env_rule: 1)

      assert build.compile_env_rule == 1
      assert [%{compile_env_rule: 1}] = results("pure_elixir")
      assert_withheld(name, toolchain_sha(build))
      assert_withheld("jason", @run_sha)
    end

    test "a revoked build or withdrawn result with rule 1 is not served" do
      name = "tc_r5_rev_#{System.unique_integer([:positive])}"

      build =
        name
        |> ingest_toolchain_build("0.1.0", deps_lock: @liveview, compile_env_rule: 1)
        |> revoke!()

      ingest_with_artifact(pure_run(@liveview, 1))
      withdraw!("pure_elixir")

      assert_withheld(name, toolchain_sha(build))
      assert_withheld("jason", @run_sha)
    end

    test "a revoked run's rule-1 result is not served" do
      ingest_with_artifact(pure_run(@decimal, 1))
      [result] = results("pure_elixir")

      sql!("UPDATE catalog_runs SET revoked_at = now() WHERE id = ANY($1)", [result.run_id])

      assert_withheld("jason", @run_sha)
    end

    test "the exemption still follows the configured list" do
      put_withheld(packages: ["decimal"])
      ingest_with_artifact(pure_run(@liveview, 1))
      assert_run_served("jason", @run_sha)
    end
  end
end
