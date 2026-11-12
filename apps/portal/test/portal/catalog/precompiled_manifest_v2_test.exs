defmodule Portal.Catalog.PrecompiledManifestV2Test do
  use Portal.DataCase, async: false

  alias Portal.{ArtifactStore, Catalog}

  import Portal.PrecompiledFixtures

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @deps %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}

  # The fixture run has no deps lock, package checksum or compile_env, which
  # format 2 requires; this is the same run with all three.
  defp keyed_run do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", @deps)
    |> Map.put("package_checksum", "outer")
    |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])
  end

  defp revoke!(build) do
    build
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(domain: Catalog)
  end

  defp builds(manifest, version), do: manifest["versions"][version]["builds"]

  defp by_target(manifest, version), do: Enum.group_by(builds(manifest, version), & &1["target"])

  test "a full run and a toolchain build are both builds; format 1 is unchanged" do
    ingest_with_artifact(keyed_run())
    v1_before = Catalog.precompiled_manifest("jason")

    ingest_toolchain_build("jason", "1.4.1", finished_at: "2026-10-24T10:00:00Z")

    assert Catalog.precompiled_manifest("jason") == v1_before
    assert Map.keys(v1_before.versions["1.4.1"]) == ["nerves_system_rpi4"]

    v2 = Catalog.precompiled_manifest_v2("jason")
    assert v2["format"] == 2
    assert v2["updated_at"] == "2026-10-24T10:00:00.000000Z"

    assert %{"nerves_system_rpi4" => [rpi4], "pure_elixir" => [tc]} = by_target(v2, "1.4.1")

    assert [%{"path" => "ebin/jason.beam"}] = rpi4["ebin"]
    assert rpi4["priv"] == []

    assert rpi4["build"] == %{
             "elixir" => "1.16.0",
             "otp" => "26",
             "dep_env" => "prod",
             "mix_target" => "rpi4",
             "system_version" => "1.24.0",
             "deps" => @deps,
             "compile_env" => [],
             "package_checksum" => "outer",
             "run_id" => "fixture-jason-1.4.1",
             "image_digest" => "sha256:precompiled"
           }

    assert [%{"path" => "ebin/jason.beam", "size" => _, "mode" => 33_188}] = tc["ebin"]

    assert %{
             "elixir" => "1.19.1",
             "otp" => "28",
             "dep_env" => "prod",
             "mix_target" => "host",
             "system_version" => nil,
             "deps" => @deps,
             "compile_env" => [],
             "package_checksum" => "outer",
             "image_digest" => "sha256:toolchain"
           } = tc["build"]

    assert "tc-" <> _ = tc["build"]["run_id"]
  end

  test "format 2 records the MIX_TARGET each build was compiled under; format 1 does not" do
    ingest_with_artifact(keyed_run())
    ingest_toolchain_build("jason", "1.4.1", finished_at: "2026-10-24T10:00:00Z")

    v2 = Catalog.precompiled_manifest_v2("jason")
    assert %{"nerves_system_rpi4" => [rpi4], "pure_elixir" => [tc]} = by_target(v2, "1.4.1")
    assert rpi4["build"]["mix_target"] == "rpi4"
    assert tc["build"]["mix_target"] == "host"

    v1 = Catalog.precompiled_manifest("jason")
    refute Map.has_key?(v1.versions["1.4.1"]["nerves_system_rpi4"]["build"], "mix_target")
  end

  test "a package with only a toolchain build has a format-2 manifest and no format-1 one" do
    name = "tc_only_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0")

    assert name in Catalog.packages_with_precompiled_files()
    assert Catalog.precompiled_manifest(name) == nil

    assert %{"versions" => %{"0.3.0" => %{"builds" => [_]}}} =
             Catalog.precompiled_manifest_v2(name)
  end

  test "a revoked toolchain build is gone at the next render" do
    name = "tc_revoked_#{System.unique_integer([:positive])}"
    build = ingest_toolchain_build(name, "0.3.0")
    assert Catalog.precompiled_manifest_v2(name)

    revoke!(build)

    assert Catalog.precompiled_manifest_v2(name) == nil
    refute name in Catalog.packages_with_precompiled_files()
  end

  test "a run without a toolchain record or keys stays in format 1 only" do
    ingest_with_artifact()

    assert %{versions: %{"1.4.1" => %{"nerves_system_rpi4" => _}}} =
             Catalog.precompiled_manifest("jason")

    assert Catalog.precompiled_manifest_v2("jason") == nil
  end

  test "a toolchain build whose blob this host lacks is left out" do
    name = "tc_missing_#{System.unique_integer([:positive])}"
    build = ingest_toolchain_build(name, "0.3.0")
    [%{"sha256" => sha}] = build.file_manifest["ebin"]
    File.rm!(ArtifactStore.blob_path(sha))

    assert Catalog.precompiled_manifest_v2(name) == nil
  end

  test "one build per target, toolchain and deps: the newest wins" do
    name = "tc_dedup_#{System.unique_integer([:positive])}"

    _old =
      ingest_toolchain_build(name, "0.3.0",
        elixir: "1.19.0",
        builder_version: 1,
        finished_at: "2026-10-01T00:00:00Z"
      )

    new =
      ingest_toolchain_build(name, "0.3.0",
        elixir: "1.19.3",
        builder_version: 2,
        finished_at: "2026-10-20T00:00:00Z"
      )

    # Same Elixir minor, other OTP: a separate build.
    _otp27 =
      ingest_toolchain_build(name, "0.3.0",
        toolchain: "1.19/27",
        otp: "27",
        finished_at: "2026-10-05T00:00:00Z"
      )

    # Same toolchain, other deps: a separate build.
    _other_deps =
      ingest_toolchain_build(name, "0.3.0",
        builder_version: 3,
        deps_lock: %{},
        finished_at: "2026-09-01T00:00:00Z"
      )

    v2 = Catalog.precompiled_manifest_v2(name)
    builds = builds(v2, "0.3.0")

    assert length(builds) == 3

    assert [winner] =
             Enum.filter(builds, &(&1["build"]["otp"] == "28" and &1["build"]["deps"] == @deps))

    assert winner["build"]["run_id"] == new.run_id
    assert v2["updated_at"] == "2026-10-20T00:00:00.000000Z"
  end

  test "a toolchain build without a package checksum is left out" do
    name = "tc_nochecksum_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", package_checksum: nil)

    assert Catalog.precompiled_manifest_v2(name) == nil
  end

  test "two system versions of one target are two builds" do
    ingest_with_artifact(
      keyed_run()
      |> Map.put("run_id", "rpi4-old")
      |> Map.put("finished_at", "2026-10-01T00:00:00Z")
    )

    ingest_with_artifact(
      keyed_run()
      |> Map.put("run_id", "rpi4-new")
      |> Map.put("finished_at", "2026-10-10T00:00:00Z")
      |> put_in(["systems", "nerves_system_rpi4", "system_version"], "1.25.0")
    )

    assert %{"nerves_system_rpi4" => rpi4} =
             by_target(Catalog.precompiled_manifest_v2("jason"), "1.4.1")

    assert rpi4 |> Enum.map(& &1["build"]["system_version"]) |> Enum.sort() == [
             "1.24.0",
             "1.25.0"
           ]
  end

  test "revoking the newer toolchain build brings the older one back" do
    name = "tc_fallback_#{System.unique_integer([:positive])}"

    old =
      ingest_toolchain_build(name, "0.3.0",
        builder_version: 1,
        finished_at: "2026-10-01T00:00:00Z"
      )

    new =
      ingest_toolchain_build(name, "0.3.0",
        builder_version: 2,
        finished_at: "2026-10-20T00:00:00Z"
      )

    assert [%{"build" => %{"run_id" => run_id}}] =
             builds(Catalog.precompiled_manifest_v2(name), "0.3.0")

    assert run_id == new.run_id

    revoke!(new)

    assert [%{"build" => %{"run_id" => run_id}}] =
             builds(Catalog.precompiled_manifest_v2(name), "0.3.0")

    assert run_id == old.run_id
  end

  test "a toolchain build that did not pass is not published" do
    name = "tc_failed_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", status: "fail")

    assert Catalog.precompiled_manifest_v2(name) == nil
    refute name in Catalog.packages_with_precompiled_files()
  end

  test "a toolchain build without a recorded compile_env is left out" do
    name = "tc_nocompileenv_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", compile_env: nil)

    assert Catalog.precompiled_manifest_v2(name) == nil
  end

  test "unknown package" do
    assert Catalog.precompiled_manifest_v2("no_such_package") == nil
  end

  # The per-target optional-dependency pass can leave a passing target with
  # its own lock (the run's plus the optional deps it kept); format 2 must
  # match against that, not the run's.
  test "a system's own deps_lock wins over the run's in format 2 as well" do
    system_deps = Map.put(@deps, "jason", %{"version" => "1.4.4", "checksum" => "xyz"})

    ingest_with_artifact(
      keyed_run()
      |> put_in(["systems", "nerves_system_rpi4", "deps_lock"], system_deps)
    )

    v2 = Catalog.precompiled_manifest_v2("jason")
    assert %{"nerves_system_rpi4" => [rpi4]} = by_target(v2, "1.4.1")
    assert rpi4["build"]["deps"] == system_deps
  end

  describe "a target build's ABI facts" do
    @toolchain "nerves_toolchain_aarch64_nerves_linux_gnu"
    @needs %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.38"], "libz.so.1" => []}

    defp set_facts!(facts) do
      {sets, params} =
        facts
        |> Enum.with_index(1)
        |> Enum.map(fn {{column, value}, i} -> {"#{column} = $#{i}", value} end)
        |> Enum.unzip()

      Repo.query!(
        "UPDATE catalog_system_results SET #{Enum.join(sets, ", ")} " <>
          "WHERE system_pkg = 'nerves_system_rpi4'",
        params
      )
    end

    defp rpi4_build do
      assert %{"nerves_system_rpi4" => [rpi4]} =
               by_target(Catalog.precompiled_manifest_v2("jason"), "1.4.1")

      rpi4
    end

    @native %{
      native: true,
      portable: true,
      elf_needs: @needs,
      otp_full: "28.1.2",
      toolchain_pkg: @toolchain,
      toolchain_version: "15.3.1"
    }

    test "a native build carries them in build" do
      ingest_with_artifact(keyed_run())
      set_facts!(@native)

      build = rpi4_build()["build"]
      assert build["native"] == true
      assert build["portable"] == true
      assert build["otp_full"] == "28.1.2"
      assert build["toolchain"] == %{"package" => @toolchain, "version" => "15.3.1"}
      assert build["elf"] == %{"needs" => @needs}
    end

    test "every key a 0.4 client reads keeps its type and value" do
      ingest_with_artifact(keyed_run())
      before = rpi4_build()
      set_facts!(@native)
      rpi4 = rpi4_build()

      assert rpi4["target"] == "nerves_system_rpi4"
      assert rpi4["ebin"] == before["ebin"]
      assert [%{"path" => "ebin/jason.beam", "mode" => 33_188, "sha256" => _}] = rpi4["ebin"]
      assert rpi4["priv"] == []

      assert Map.take(rpi4["build"], [
               "elixir",
               "otp",
               "system_version",
               "deps",
               "compile_env",
               "package_checksum",
               "dep_env",
               "mix_target"
             ]) == %{
               "elixir" => "1.16.0",
               "otp" => "26",
               "system_version" => "1.24.0",
               "deps" => @deps,
               "compile_env" => [],
               "package_checksum" => "outer",
               "dep_env" => "prod",
               "mix_target" => "rpi4"
             }

      assert Map.drop(rpi4["build"], ~w(native portable otp_full toolchain elf)) ==
               before["build"]

      v2 = Catalog.precompiled_manifest_v2("jason")
      assert v2["format"] == 2
    end

    test "a beam-only build says so and carries no elf" do
      ingest_with_artifact(keyed_run())
      set_facts!(%{@native | native: false, elf_needs: %{}})

      build = rpi4_build()["build"]
      assert build["native"] == false
      assert build["portable"] == true
      refute Map.has_key?(build, "elf")
    end

    test "unknown facts are left out, and format 1 never carries them" do
      ingest_with_artifact(keyed_run())
      v1_before = Catalog.precompiled_manifest("jason")

      build = rpi4_build()["build"]

      for key <- ~w(native portable otp_full toolchain elf),
          do: refute(Map.has_key?(build, key), key)

      assert Catalog.precompiled_manifest_v2("jason")["format"] == 2

      set_facts!(@native)
      assert Catalog.precompiled_manifest("jason") == v1_before
    end

    test "a toolchain without its package or version is left out" do
      ingest_with_artifact(keyed_run())
      set_facts!(%{toolchain_pkg: @toolchain})
      refute Map.has_key?(rpi4_build()["build"], "toolchain")
    end

    test "the fingerprint changes when the ELF facts arrive" do
      ingest_with_artifact(keyed_run())
      before = Catalog.precompiled_fingerprints()["jason"]

      set_facts!(%{elf_needs: @needs})
      after_needs = Catalog.precompiled_fingerprints()["jason"]
      assert after_needs != before

      set_facts!(%{native: true})
      assert Catalog.precompiled_fingerprints()["jason"] != after_needs
    end

    test "a rendered build conforms to the published schema" do
      ingest_with_artifact(keyed_run())
      set_facts!(@native)

      PortalWeb.ApiSpecAssertions.assert_api_schema(
        Catalog.precompiled_manifest_v2("jason"),
        "ManifestV2"
      )
    end
  end

  describe "config variants" do
    test "four config variants of one build are listed side by side; each keeps its newest" do
      drop_legacy_identity_index!()

      default =
        ingest_toolchain_build("cvm", "1.0.0", compile_env: lv_default_env(), compile_env_rule: 1)

      named =
        for name <- Compatibility.ConfigVariants.names(), into: %{} do
          {name,
           ingest_toolchain_build("cvm", "1.0.0",
             config_variant: name,
             compile_env: overlay_env(name),
             compile_env_rule: 1
           )}
        end

      # An older builder version's default and phx_prod: the newer of each
      # replaces its predecessor, and neither shadows the other variants.
      for config_variant <- ["default", "phx_prod"] do
        env =
          if config_variant == "default", do: lv_default_env(), else: overlay_env(config_variant)

        ingest_toolchain_build("cvm", "1.0.0",
          config_variant: config_variant,
          builder_version: 0,
          finished_at: "2026-10-01T10:00:00Z",
          compile_env: env,
          compile_env_rule: 1
        )
      end

      builds = builds(Catalog.precompiled_manifest_v2("cvm"), "1.0.0")
      assert length(builds) == 4

      by_variant = Map.new(builds, &{&1["build"]["config_variant"] || "default", &1})
      assert Map.keys(by_variant) |> Enum.sort() == ["default", "phx_dev", "phx_prod", "phx_test"]
      refute Map.has_key?(by_variant["default"]["build"], "config_variant")
      assert by_variant["default"]["build"]["run_id"] == default.run_id

      for {name, row} <- named do
        assert by_variant[name]["build"]["run_id"] == row.run_id
        assert by_variant[name]["build"]["compile_env"] == overlay_env(name)
      end
    end

    test "a package without named variants renders exactly as before" do
      ingest_toolchain_build("cvn", "1.0.0", compile_env: [], compile_env_rule: 1)
      [build] = builds(Catalog.precompiled_manifest_v2("cvn"), "1.0.0")

      assert Map.keys(build["build"]) |> Enum.sort() ==
               ~w(compile_env dep_env deps elixir image_digest mix_target otp package_checksum run_id system_version)
    end

    test "format 1 never lists a toolchain build, variant or not" do
      drop_legacy_identity_index!()
      ingest_with_artifact(keyed_run())
      before = Catalog.precompiled_manifest("jason")
      ingest_toolchain_build("jason", "1.4.1", compile_env: lv_default_env(), compile_env_rule: 1)

      ingest_toolchain_build("jason", "1.4.1",
        config_variant: "phx_prod",
        compile_env: overlay_env("phx_prod"),
        compile_env_rule: 1
      )

      assert Catalog.precompiled_manifest("jason") == before
      assert length(builds(Catalog.precompiled_manifest_v2("jason"), "1.4.1")) == 3
    end
  end
end
