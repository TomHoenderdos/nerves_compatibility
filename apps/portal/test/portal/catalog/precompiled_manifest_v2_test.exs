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
             "system_version" => nil,
             "deps" => @deps,
             "compile_env" => [],
             "package_checksum" => "outer",
             "image_digest" => "sha256:toolchain"
           } = tc["build"]

    assert "tc-" <> _ = tc["build"]["run_id"]
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
end
