defmodule Portal.Catalog.ToolchainEarlierBuildsTest do
  @moduledoc """
  A rebuild of a toolchain build identity with another dependency lock keeps
  the build it replaced (`Portal.Catalog.ToolchainBuild.EarlierBuilds`): a
  project still locked at the older dependency keeps its hit.
  """

  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.ToolchainBuild
  alias Portal.Catalog.ToolchainBuild.EarlierBuilds
  alias Portal.Precompiled.ToolchainRevocation

  defp name, do: "earlier_#{System.unique_integer([:positive])}"

  defp lock(certifi), do: %{"certifi" => %{"version" => certifi, "checksum" => "c-#{certifi}"}}

  defp builds(name) do
    case Catalog.precompiled_manifest_v2(name) do
      nil -> []
      %{"versions" => versions} -> versions |> Map.values() |> Enum.flat_map(& &1["builds"])
    end
  end

  defp served_locks(name),
    do:
      name
      |> builds()
      |> Enum.map(&get_in(&1, ["build", "deps", "certifi", "version"]))
      |> Enum.sort()

  defp memberships(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT sha256 FROM catalog_artifact_memberships WHERE toolchain_build_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp shas(%{"ebin" => ebin}), do: Enum.map(ebin, & &1["sha256"])

  test "a rebuild with another lock keeps serving the build it replaced" do
    name = name()
    old = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    new = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))

    assert new.id == old.id
    assert new.deps_lock == lock("2.19.0")
    assert [%{"deps_lock" => kept}] = new.earlier_builds
    assert kept == lock("2.18.0")

    assert served_locks(name) == ["2.18.0", "2.19.0"]

    assert MapSet.equal?(
             memberships(new.id),
             MapSet.new(shas(old.file_manifest) ++ shas(new.file_manifest))
           )
  end

  test "a rebuild with the same lock keeps no earlier build" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    new = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    assert new.earlier_builds in [nil, []]
    assert served_locks(name) == ["2.18.0"]
    assert MapSet.equal?(memberships(new.id), MapSet.new(shas(new.file_manifest)))
  end

  test "at most #{EarlierBuilds.max()} earlier builds are kept, newest first" do
    name = name()
    versions = for minor <- 15..19, do: "2.#{minor}.0"
    for version <- versions, do: ingest_toolchain_build(name, "0.4.0", deps_lock: lock(version))

    row = row(name)
    kept = Enum.map(row.earlier_builds, &get_in(&1, ["deps_lock", "certifi", "version"]))
    assert kept == ["2.18.0", "2.17.0", "2.16.0"]
    assert served_locks(name) == ["2.16.0", "2.17.0", "2.18.0", "2.19.0"]
  end

  test "a rebuild back to an earlier lock drops that lock from the earlier builds" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    back = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    assert [%{"deps_lock" => kept}] = back.earlier_builds
    assert kept == lock("2.19.0")
    assert served_locks(name) == ["2.18.0", "2.19.0"]
  end

  # A refusal or a skip is a verdict on the package's build, not on a lock.
  test "a rebuild that does not pass drops the earlier builds with its own" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    skipped = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.20.0"), status: "skipped")

    assert skipped.earlier_builds == []
    assert memberships(skipped.id) == MapSet.new()
    assert served_locks(name) == []
  end

  test "a revoked row serves none of its earlier builds" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    passing = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    assert served_locks(name) == ["2.18.0", "2.19.0"]

    passing |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    assert served_locks(name) == []
  end

  # `ToolchainRevocation.revoke(judge_revision: n)` takes rows judged at `n`
  # or later. A rebuild on an image at a lower revision (a rollback, or a
  # builder not yet updated) must not keep the build that revocation would
  # take beside a row it leaves alone.
  test "a judge-revision revocation that would take an earlier build takes its row" do
    name = name()
    rule2 = [portability_rule: 2, builder_version: Portal.Toolchains.builder_version()]
    ingest_toolchain_build(name, "0.4.0", [deps_lock: lock("2.18.0"), judge_revision: 5] ++ rule2)
    ingest_toolchain_build(name, "0.4.0", [deps_lock: lock("2.19.0"), judge_revision: 4] ++ rule2)

    ToolchainRevocation.revoke(dry_run: false, judge_revision: 5, package: name)

    refute "2.18.0" in served_locks(name)
  end

  # `ToolchainRevocation.revoke(rule1_prefix: p)` takes rows whose rule-1
  # reason starts with `p`.
  test "a rule-1 prefix revocation that would take an earlier build takes its row" do
    name = name()
    opts = [portability_rule: 2, builder_version: Portal.Toolchains.builder_version()]

    ingest_toolchain_build(
      name,
      "0.4.0",
      [deps_lock: lock("2.18.0"), rule1_reason: "calls erlang:open_port/2"] ++ opts
    )

    ingest_toolchain_build(
      name,
      "0.4.0",
      [deps_lock: lock("2.19.0"), rule1_reason: "calls System.cmd/3"] ++ opts
    )

    ToolchainRevocation.revoke(dry_run: false, rule1_prefix: "calls erlang:open_port/")

    refute "2.18.0" in served_locks(name)
  end

  # `Portal.Workers.ClosureDrift` keeps the build before its rebuild, and a
  # release that does not know the column ingests that rebuild: its upsert
  # rewrites the row's verdict and never looks at the entries. A revocation
  # judges each entry by its own verdict, and revokes the row it hangs off.
  test "a revocation that would take an earlier build takes its row, whatever the row's verdict" do
    name = name()

    built =
      ingest_toolchain_build(name, "0.4.0",
        deps_lock: lock("2.18.0"),
        portability_rule: 2,
        rule1_reason: "calls erlang:open_port/2",
        builder_version: Portal.Toolchains.builder_version()
      )

    built
    |> Ash.Changeset.for_update(:record_earlier_builds, %{
      earlier_builds: EarlierBuilds.keep(built)
    })
    |> Ash.update!(domain: Catalog)

    Repo.query!(
      """
      UPDATE catalog_toolchain_builds
      SET deps_lock = $2, portability_rule = 1, rule1_reason = NULL, run_id = 'tc-old-release'
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(built.id), lock("2.19.0")]
    )

    assert {:revoked, 1, [%{rule1_reason: "calls erlang:open_port/2"}], _at} =
             ToolchainRevocation.revoke(dry_run: false, everything: true, package: name)

    assert served_locks(name) == []
  end

  # The files route and the package list publish a row's memberships by the
  # row's own lock (`Portal.Precompiled.Withheld`), earlier builds' files
  # included: a manifest that listed an earlier build beside a withheld row
  # would name files the route refuses.
  test "an earlier build is listed only beside a row that is not withheld" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    ingest_toolchain_build(name, "0.4.0",
      deps_lock: Map.put(lock("2.19.0"), "phoenix_live_view", %{"version" => "1.1.0"})
    )

    listed =
      for build <- builds(name),
          key <- ["ebin", "priv"],
          file <- build[key] || [],
          do: file["sha256"]

    assert Enum.all?(listed, &Catalog.published_sha256?/1)
    assert served_locks(name) == []
  end

  # A named config variant row is served only while it records its own
  # config reads, and its earlier builds only beside it
  # (`@served_toolchain_builds`). A release that does not know
  # `compile_env_run_id` rewrites the row with its own `run_id` and leaves
  # the mark, which then vouches for nothing, while an earlier build kept on
  # the row still carries a mark of its own.
  test "an earlier build of a named config variant is listed only beside a served row" do
    drop_legacy_identity_index!()
    name = name()

    ingest_toolchain_build(name, "0.4.0",
      deps_lock: lock("2.19.0"),
      compile_env: lv_default_env(),
      compile_env_rule: 1
    )

    named = [
      config_variant: "phx_prod",
      compile_env: overlay_env("phx_prod"),
      compile_env_rule: 1
    ]

    ingest_toolchain_build(name, "0.4.0", [deps_lock: lock("2.18.0")] ++ named)
    row = ingest_toolchain_build(name, "0.4.0", [deps_lock: lock("2.19.0")] ++ named)
    assert served_locks(name) == ["2.18.0", "2.19.0", "2.19.0"]

    Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'tc-old-release' WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    listed =
      for build <- builds(name),
          key <- ["ebin", "priv"],
          file <- build[key] || [],
          do: file["sha256"]

    assert Enum.all?(listed, &Catalog.published_sha256?/1)
    assert served_locks(name) == ["2.19.0"]
  end

  # `Portal.Workers.ClosureDrift` keeps the row's build before queueing its
  # rebuild, and a release that does not know the column may ingest one that
  # came back with the same lock and the same files. The newest per key is
  # picked within each list only: the build the rebuild replaced must not
  # stay in `builds` while the rebuild's inputs move the row to
  # `builds_with_inputs`, where a client takes the old one when they differ.
  test "an earlier build with the row's own lock is never listed" do
    name = name()
    built = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    built
    |> Ash.Changeset.for_update(:record_earlier_builds, %{
      earlier_builds: EarlierBuilds.keep(built)
    })
    |> Ash.update!(domain: Catalog)

    Repo.query!(
      """
      UPDATE catalog_toolchain_builds
      SET run_id = 'tc-old-release', compile_inputs = $2,
          finished_at = finished_at + interval '1 day'
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(built.id), [%{"kind" => "env_all"}]]
    )

    version = Catalog.precompiled_manifest_v2(name)["versions"]["0.4.0"]

    assert version["builds"] == []
    assert [%{"build" => %{"run_id" => "tc-old-release"}}] = version["builds_with_inputs"]
  end

  # A rebuild un-revokes a row only once `Catalog.mark_withheld_revoked/2`
  # marked it. This release's ingest of that rebuild drops the earlier
  # builds the revocation hid with the row (`EarlierBuilds.push/3`), but a
  # release that does not know the column un-revokes the row and leaves
  # them: the mark drops them first.
  test "marking a revoked row for its rebuild drops the earlier builds it hid" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    live_view = %{"version" => "1.1.0", "checksum" => "lv"}

    row =
      ingest_toolchain_build(name, "0.4.0",
        deps_lock: Map.put(lock("2.19.0"), "phoenix_live_view", live_view)
      )

    row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    assert %{marked: [_]} = Catalog.mark_withheld_revoked([row.id], dry_run: false)

    # What the older release's ingest of the rebuild leaves: config reads
    # recorded, so `:unrevoke_rebuilt` took the revocation off.
    Repo.query!(
      """
      UPDATE catalog_toolchain_builds
      SET revoked_at = NULL, revoked_reason = NULL, compile_env_rule = 1,
          compile_env = ARRAY[]::jsonb[], compile_env_run_id = run_id
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(row.id)]
    )

    assert served_locks(name) == ["2.19.0"]
  end

  # A row's memberships hold its earlier builds' files too, but a build
  # serves only the files its own manifest lists, each earlier build judged
  # as a virtual row of the row.
  test "a withheld earlier build's file is not fetchable by hash" do
    name = name()
    live_view = %{"version" => "1.1.0", "checksum" => "lv"}

    withheld =
      ingest_toolchain_build(name, "0.4.0",
        deps_lock: Map.put(lock("2.18.0"), "phoenix_live_view", live_view)
      )

    row = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))

    assert [_] = row.earlier_builds
    assert served_locks(name) == ["2.19.0"]
    assert MapSet.member?(memberships(row.id), hd(shas(withheld.file_manifest)))
    assert Catalog.published_sha256?(hd(shas(row.file_manifest)))
    refute Catalog.published_sha256?(hd(shas(withheld.file_manifest)))
    assert name in Catalog.packages_with_precompiled_files()
  end

  test "an earlier build whose file the row no longer owns is left out whole" do
    name = name()
    old = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))

    # What a release that does not know the column leaves behind: its ingest
    # replaces the row's memberships with its own build's files alone.
    Repo.query!(
      "DELETE FROM catalog_artifact_memberships WHERE toolchain_build_id = $1 AND sha256 = ANY($2)",
      [Ecto.UUID.dump!(old.id), shas(old.file_manifest)]
    )

    assert served_locks(name) == ["2.19.0"]
  end

  describe "push/3" do
    defp passing(certifi, overrides \\ []) do
      struct!(
        %ToolchainBuild{
          status: :pass,
          deps_lock: lock(certifi),
          file_manifest: %{"ebin" => []},
          finished_at: ~U[2026-11-01 00:00:00.000000Z]
        },
        overrides
      )
    end

    # An entry as `EarlierBuilds.entry/1` records one: its verdict keys too.
    defp recorded(certifi, verdict \\ %{}) do
      Map.merge(
        %{
          "deps_lock" => lock(certifi),
          "portability_rule" => nil,
          "rule1_reason" => nil,
          "judge_revision" => nil
        },
        verdict
      )
    end

    test "puts the replaced build first and drops any of the new lock" do
      replaced =
        passing("2.18.0", earlier_builds: [recorded("2.19.0"), recorded("2.17.0")])

      assert [%{"deps_lock" => first}, %{"deps_lock" => second}] =
               EarlierBuilds.push(replaced, replaced.earlier_builds, passing("2.19.0"))

      assert first == lock("2.18.0")
      assert second == lock("2.17.0")
    end

    # A row that serves nothing hid its earlier builds with its own: a skip
    # or a refusal in between is a verdict on them too (a release that does
    # not know the column leaves them on a skipped row), and a revocation
    # covered them. A later passing build does not bring them back.
    test "drops the list when the replaced row serves nothing" do
      earlier = [recorded("2.17.0")]

      for replaced <- [
            passing("2.18.0", status: :skipped, file_manifest: nil, earlier_builds: earlier),
            passing("2.18.0",
              revoked_at: ~U[2026-11-01 00:00:00.000000Z],
              earlier_builds: earlier
            )
          ] do
        assert EarlierBuilds.push(replaced, earlier, passing("2.19.0")) == []
      end
    end

    test "keeps the list as it was when there was no row" do
      earlier = [recorded("2.17.0")]
      assert EarlierBuilds.push(nil, earlier, passing("2.19.0")) == earlier
    end

    test "keeps nothing beside a rebuild that does not pass" do
      assert EarlierBuilds.push(passing("2.18.0"), [], passing("2.19.0", status: :skipped)) == []
    end

    # A revocation judges an entry by its own verdict and revokes its row
    # (`Portal.Precompiled.ToolchainRevocation`), so an entry is kept beside
    # a row of any verdict.
    test "keeps a build whatever the new row's verdict" do
      rule2 = passing("2.18.0", portability_rule: 2, rule1_reason: "reads os:type/0")

      assert [%{"deps_lock" => kept, "rule1_reason" => "reads os:type/0"}] =
               EarlierBuilds.push(rule2, [], passing("2.19.0", portability_rule: 1))

      assert kept == lock("2.18.0")
    end
  end

  # Review S5 S1: a build kept as an earlier build is served under its own
  # run id, which the plugin watch keys on. A replaced build with no plugin
  # record that may have run a plugin gets the withholding mark for its run,
  # so the watch cannot miss it; one with a record, or one that ran none, is
  # served as before.
  describe "an earlier build that may have run a rebar3 plugin" do
    alias Portal.Precompiled.PluginWatch

    setup do
      PluginWatch.refresh(plugin_registry())
      :ok
    end

    @pubkey %{"module" => "pubkey_os_cacerts", "function" => "on_load", "arity" => 0}
    @ran_hex %{"owner" => "dep", "name" => "rebar3_hex", "version" => "7.5.0"}

    # A lock whose second release is `extra` (name and version).
    defp lock_with(certifi, {name, version}),
      do: Map.put(lock(certifi), name, %{"version" => version, "checksum" => "x"})

    defp ingest_pair(old_opts, new_opts) do
      name = name()

      old =
        ingest_toolchain_build(
          name,
          "0.4.0",
          Keyword.merge([deps_lock: lock("2.18.0")], old_opts)
        )

      new =
        ingest_toolchain_build(
          name,
          "0.4.0",
          Keyword.merge([deps_lock: lock("2.19.0")], new_opts)
        )

      {name, old, new}
    end

    defp recorded_none,
      do: [compile_observations: %{"rebar3_plugins" => [], "os_type_reads" => []}]

    test "a replaced build with the plugin mark and no record is withheld" do
      {name, old, _new} =
        ingest_pair([compile_observations: %{"os_type_reads" => [@pubkey]}], recorded_none())

      assert PluginWatch.ran(old.run_id) == [{"*", "unrecorded"}]
      assert served_locks(name) == ["2.19.0"]
      refute Enum.any?(shas(old.file_manifest), &Catalog.published_sha256?/1)
    end

    test "a replaced build from before os_type_reads is withheld when its closure declares a plugin" do
      # mimerl 1.0.0's rebar.config runs rebar3_hex (the 2026-11-21 scan).
      declared = [deps_lock: lock_with("2.18.0", {"mimerl", "1.0.0"})]
      {name, old, _new} = ingest_pair(declared, recorded_none())

      assert PluginWatch.ran(old.run_id) == [{"*", "unrecorded"}]
      assert served_locks(name) == ["2.19.0"]

      # Built after os_type_reads without the mark: rebar3 fetched no plugin.
      {name, old, _new} =
        ingest_pair(
          [
            deps_lock: lock_with("2.18.0", {"mimerl", "1.0.0"}),
            compile_observations: %{"os_type_reads" => []}
          ],
          recorded_none()
        )

      assert PluginWatch.ran(old.run_id) == []
      assert served_locks(name) == ["2.18.0", "2.19.0"]

      # Nothing declares a plugin, and the rebuild ran none.
      {name, old, _new} = ingest_pair([], recorded_none())
      assert PluginWatch.ran(old.run_id) == []
      assert served_locks(name) == ["2.18.0", "2.19.0"]

      # yamerl 0.10.0's script adds only coveralls, which a build judged
      # before S5 refused: a passing one did not run it.
      {name, old, _new} =
        ingest_pair([deps_lock: lock_with("2.18.0", {"yamerl", "0.10.0"})], recorded_none())

      assert PluginWatch.ran(old.run_id) == []
      assert served_locks(name) == ["2.18.0", "2.19.0"]
    end

    test "a replaced build with no record is withheld when the rebuild ran a plugin" do
      ran = [
        compile_observations: %{"rebar3_plugins" => [@ran_hex], "os_type_reads" => [@pubkey]}
      ]

      {name, old, new} = ingest_pair([], ran)

      assert PluginWatch.ran(old.run_id) == [{"*", "unrecorded"}]
      assert PluginWatch.ran(new.run_id) == [{"rebar3_hex", "7.5.0"}]
      assert served_locks(name) == ["2.19.0"]
    end

    test "a replaced build with a record is served by the watch alone" do
      ran = [
        compile_observations: %{"rebar3_plugins" => [@ran_hex], "os_type_reads" => [@pubkey]}
      ]

      {name, old, _new} = ingest_pair(ran, ran)

      assert PluginWatch.ran(old.run_id) == [{"rebar3_hex", "7.5.0"}]
      assert served_locks(name) == ["2.18.0", "2.19.0"]

      PluginWatch.refresh(plugin_registry([{"rebar3_hex", ["7.5.0", "9.0.0"]}]))
      assert served_locks(name) == []

      {name, old, _new} = ingest_pair(recorded_none(), recorded_none())
      assert PluginWatch.ran(old.run_id) == []
      assert served_locks(name) == ["2.18.0", "2.19.0"]
    end

    # Earlier builds kept before this rule (no `plugins` fact on the entry),
    # and host-native builds, which no requeue rebuilds: the sweep the update
    # check runs every hour marks the same way.
    test "the sweep marks an earlier build kept before the rule" do
      {name, old, new} =
        ingest_pair([deps_lock: lock_with("2.18.0", {"mimerl", "1.0.0"})], recorded_none())

      Repo.query!("DELETE FROM rebar3_plugin_runs WHERE run_id = $1", [old.run_id])

      Repo.query!(
        "UPDATE catalog_toolchain_builds SET earlier_builds = " <>
          "ARRAY(SELECT e - 'plugins' FROM unnest(earlier_builds) e) WHERE id = $1",
        [Ecto.UUID.dump!(new.id)]
      )

      assert served_locks(name) == ["2.18.0", "2.19.0"]
      assert :ok = PluginWatch.mark_unrecorded()
      assert PluginWatch.ran(old.run_id) == [{"*", "unrecorded"}]
      assert served_locks(name) == ["2.19.0"]

      # Idempotent.
      assert :ok = PluginWatch.mark_unrecorded()
      assert PluginWatch.ran(old.run_id) == [{"*", "unrecorded"}]
    end
  end

  defp row(name) do
    ToolchainBuild
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read_one!(domain: Catalog)
  end
end
