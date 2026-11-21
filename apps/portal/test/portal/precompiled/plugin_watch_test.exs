defmodule Portal.Precompiled.PluginWatchTest do
  # A build that ran a rebar3 plugin release is served only while Hex has
  # no release of that plugin package (or of a plugin dependency it ran)
  # outside the review (`Compatibility.RebarPlugins`): a new one withholds
  # every such build, and once it is reviewed they are served again (review
  # S5 S1).
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.Catalog
  alias Portal.Precompiled.PluginWatch

  defp ran(
         name,
         version,
         sha \\ "62f57c91c6300bd496624b432bc36c7c08e29f4e7bb6fde814ab9e3775753ddd"
       ) do
    %{"owner" => "dep", "name" => name, "version" => version, "sha256" => sha}
  end

  defp observations(plugins), do: %{"rebar3_plugins" => plugins, "problems" => []}

  defp registry(entries) do
    for {name, versions} <- entries,
        do: %{
          name: name,
          latest_version: List.last(versions),
          versions: versions,
          updated_at: nil
        }
  end

  @package_id "0b9c6f5e-3d0c-4e57-9a43-0c7f1d2e8a11"

  @reviewed_hex Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Map.keys() |> Enum.sort()

  describe "record/3" do
    test "keeps each plugin release a run ran, once" do
      plugins = [
        ran("rebar3_hex", "7.5.0"),
        ran("hex_core", "0.21.1", nil),
        ran("rebar3_hex", "7.5.0")
      ]

      assert :ok = PluginWatch.record(@package_id, "tc-1", observations(plugins))
      assert :ok = PluginWatch.record(@package_id, "tc-1", observations(plugins))
      assert :ok = PluginWatch.record(@package_id, "tc-2", %{"truncated" => true})
      assert :ok = PluginWatch.record(@package_id, "tc-3", nil)
      assert :ok = PluginWatch.record(@package_id, nil, observations(plugins))

      assert PluginWatch.ran("tc-1") == [{"hex_core", "0.21.1"}, {"rebar3_hex", "7.5.0"}]
      assert PluginWatch.ran("tc-2") == []
    end

    # Review S5 R3: deduplicated first and never cut; a record that is over
    # the bound or malformed withholds the build whatever the watch holds.
    test "a record over the bound, or malformed, is the withholding mark" do
      max = PluginWatch.max_releases()
      many = for i <- 1..(max + 1), do: ran("rebar3_hex", "7.#{i}.0")
      dup = for _ <- 1..(max + 5), do: ran("rebar3_hex", "7.5.0")

      assert :ok = PluginWatch.record(@package_id, "tc-dup", observations(dup))
      assert PluginWatch.ran("tc-dup") == [{"rebar3_hex", "7.5.0"}]

      assert :ok = PluginWatch.record(@package_id, "tc-many", observations(many))
      assert PluginWatch.ran("tc-many") == [{"*", "unrecorded"}]

      for {id, bad} <- [
            {"tc-bad-name", [%{"name" => "Bad Name", "version" => "1.0.0"}]},
            {"tc-no-version", [ran("rebar3_hex", "7.5.0"), %{"name" => "verl"}]},
            {"tc-junk", ["junk"]},
            {"tc-not-list", %{"name" => "x"}}
          ] do
        assert :ok = PluginWatch.record(@package_id, id, %{"rebar3_plugins" => bad})
        assert PluginWatch.ran(id) == [{"*", "unrecorded"}], id
      end
    end
  end

  describe "refresh/1" do
    test "a release outside the review is watched; reviewing it clears the watch" do
      assert PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}, {"pc", ["1.0.0"]}])) ==
               %{}

      watched = PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex ++ ["7.6.0"]}]))
      assert watched == %{"rebar3_hex" => ["7.6.0"]}
      assert PluginWatch.watched() == %{"rebar3_hex" => ["7.6.0"]}

      # A package missing from a registry read keeps what it had.
      assert PluginWatch.refresh(registry([{"verl", ["1.1.1"]}])) == %{"rebar3_hex" => ["7.6.0"]}

      # A prerelease or a backport outside the review counts too.
      assert PluginWatch.refresh(registry([{"verl", ["1.1.1", "1.2.0-rc.1"]}])) ==
               %{"rebar3_hex" => ["7.6.0"], "verl" => ["1.2.0-rc.1"]}

      assert PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}, {"verl", ["1.1.1"]}])) ==
               %{}

      assert PluginWatch.watched() == %{}
    end
  end

  describe "serving" do
    setup do
      name = "plugwatch_#{System.unique_integer([:positive])}"

      build =
        ingest_toolchain_build(name, "1.0.0",
          compile_observations: observations([ran("rebar3_hex", "7.5.0")])
        )

      other = "plugwatch_none_#{System.unique_integer([:positive])}"
      plain = ingest_toolchain_build(other, "1.0.0", compile_observations: observations([]))

      # A fresh watch with nothing in it.
      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}]))
      %{name: name, sha: ebin_sha(build), other: other, other_sha: ebin_sha(plain)}
    end

    defp ebin_sha(build), do: hd(build.file_manifest["ebin"])["sha256"]

    defp served?(name) do
      case Catalog.precompiled_manifest_v2(name) do
        nil ->
          false

        manifest ->
          manifest["versions"] |> Map.values() |> Enum.flat_map(& &1["builds"]) |> Enum.any?()
      end
    end

    test "an unreviewed release of a plugin a build ran withholds it everywhere, and reviewing it serves it again",
         ctx do
      assert served?(ctx.name)
      assert Catalog.published_sha256?(ctx.sha)
      assert ctx.name in Catalog.packages_with_precompiled_files()
      before = Catalog.precompiled_fingerprints()[ctx.name]
      other_before = Catalog.precompiled_fingerprints()[ctx.other]

      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex ++ ["7.6.0"]}]))

      refute served?(ctx.name)
      refute Catalog.published_sha256?(ctx.sha)
      refute ctx.name in Catalog.packages_with_precompiled_files()
      assert Catalog.precompiled_fingerprints()[ctx.name] != before

      # A build that ran no plugin is not touched, nor is its package's
      # fingerprint: only the packages that ran a watched plugin render
      # again (review S5 N8).
      assert served?(ctx.other)
      assert Catalog.published_sha256?(ctx.other_sha)
      assert Catalog.precompiled_fingerprints()[ctx.other] == other_before

      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}]))

      assert served?(ctx.name)
      assert Catalog.published_sha256?(ctx.sha)
      assert ctx.name in Catalog.packages_with_precompiled_files()
      assert Catalog.precompiled_fingerprints()[ctx.name] == before

      # A watched plugin the package never ran leaves its fingerprint alone.
      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}, {"verl", ["9.9.9"]}]))
      assert PluginWatch.watched() == %{"verl" => ["9.9.9"]}
      assert served?(ctx.name)
      assert Catalog.precompiled_fingerprints()[ctx.name] == before
    end

    test "a build whose record is the withholding mark is withheld while nothing is watched",
         ctx do
      Portal.Repo.query!(
        "INSERT INTO rebar3_plugin_runs (run_id, package, version, sha256, package_id) " <>
          "SELECT run_id, '*', 'unrecorded', NULL, t.package_id FROM catalog_toolchain_builds t " <>
          "JOIN catalog_packages p ON p.id = t.package_id WHERE p.name = $1",
        [ctx.name]
      )

      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}]))
      refute served?(ctx.name)
      refute Catalog.published_sha256?(ctx.sha)
      assert served?(ctx.other)
    end

    # Review S5 R4: the guard fails closed. A watch the update check has not
    # refreshed in 6 hours, or never, withholds every build that ran a
    # plugin; the next refresh serves them again.
    test "a stale or never written watch withholds every build that ran a plugin", ctx do
      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}]))
      assert served?(ctx.name)
      fresh = Catalog.precompiled_fingerprints()[ctx.name]
      other_fresh = Catalog.precompiled_fingerprints()[ctx.other]

      Portal.Repo.query!(
        "UPDATE rebar3_plugin_watch_state SET checked_at = now() - interval '7 hours'",
        []
      )

      refute served?(ctx.name)
      refute Catalog.published_sha256?(ctx.sha)
      refute ctx.name in Catalog.packages_with_precompiled_files()
      assert Catalog.precompiled_fingerprints()[ctx.name] != fresh
      # A build that ran no plugin is not touched, nor its fingerprint (N8).
      assert served?(ctx.other)
      assert Catalog.precompiled_fingerprints()[ctx.other] == other_fresh

      Portal.Repo.query!("DELETE FROM rebar3_plugin_watch_state", [])
      refute served?(ctx.name)
      refute Catalog.published_sha256?(ctx.sha)

      PluginWatch.refresh(registry([{"rebar3_hex", @reviewed_hex}]))
      assert served?(ctx.name)
      assert Catalog.published_sha256?(ctx.sha)
      assert Catalog.precompiled_fingerprints()[ctx.name] == fresh
    end

    test "a watched dependency of the plugin withholds it too", ctx do
      Portal.Repo.query!(
        "INSERT INTO rebar3_plugin_runs (run_id, package, version, sha256, package_id) " <>
          "SELECT run_id, 'hex_core', '0.21.1', NULL, t.package_id FROM catalog_toolchain_builds t " <>
          "JOIN catalog_packages p ON p.id = t.package_id WHERE p.name = $1",
        [ctx.name]
      )

      PluginWatch.refresh(registry([{"hex_core", ["0.21.1", "0.22.0"]}]))
      refute served?(ctx.name)
      refute Catalog.published_sha256?(ctx.sha)
      assert served?(ctx.other)
    end
  end
end
