defmodule Portal.PinnedManifestTest do
  # Pinned builds are served only under a version's `builds_closure`, under
  # the lock they were built with, and every lever that withdraws a build,
  # the files route and the batch fingerprint cover them.
  use Portal.DataCase, async: false

  import Portal.PinnedFixtures
  import Portal.PrecompiledFixtures, only: [plugin_registry: 0, plugin_registry: 1]

  alias Portal.Catalog
  alias Portal.Precompiled.{DeterministicRevocation, ToolchainRevocation}

  @b String.duplicate("b", 64)

  defp version(name) do
    case Catalog.precompiled_manifest_v2(name) do
      %{"versions" => %{"1.0.0" => version}} -> version
      other -> other
    end
  end

  defp ingested(opts \\ []) do
    name = unique()
    pins = pins(name)
    {:ok, row} = ingest(name, pins, opts)
    %{name: name, pins: pins, row: row, sha: sha("beam-" <> name)}
  end

  defp dep(name, version),
    do: %{"name" => name, "hex" => name, "version" => version, "checksum" => @b}

  test "a pinned build is listed under builds_closure only, with the lock it was built with" do
    %{name: name, row: row} = ingested()

    assert %{"builds" => [], "builds_closure" => [entry]} = version = version(name)
    refute Map.has_key?(version, "builds_with_inputs")
    assert entry["target"] == "pure_elixir"
    assert entry["build"]["deps"] == row.deps_lock
    assert entry["build"]["variant"] == "pinned"
    assert entry["build"]["run_id"] == row.run_id
    refute Map.has_key?(entry, :closure_only)

    # Format 1 never lists one.
    assert Catalog.precompiled_manifest(name) == nil
    assert name in Catalog.packages_with_precompiled_files()
  end

  test "a skipped or withheld pinned build is not served" do
    name = unique()
    {:ok, _} = ingest(name, pins(name), lock: %{})
    assert version(name) == nil

    withheld = unique()
    lv = pins(withheld, [dep("phoenix_live_view", "1.0.0")])
    {:ok, row} = ingest(withheld, lv, compile_env_rule: nil)
    assert version(withheld) == nil
    refute Catalog.published_sha256?(sha("beam-" <> withheld))
    assert row.status == :pass
  end

  # Review S5 S1: a pinned build that ran a rebar3 plugin is withheld while
  # Hex has a release of it nobody reviewed, and served again once it is.
  test "a pinned build that ran a watched plugin is withheld, and served again once reviewed" do
    plugins = %{
      "rebar3_plugins" => [%{"owner" => "dep", "name" => "rebar3_hex", "version" => "7.5.0"}]
    }

    %{name: name, sha: sha} = ingested(observations: plugins)
    reviewed = Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Map.keys()

    # A watch never written withholds it too (review S5 R4).
    assert version(name) == nil

    Portal.Precompiled.PluginWatch.refresh(plugin_registry())

    assert %{"builds_closure" => [_]} = version(name)

    watch = &Portal.Precompiled.PluginWatch.refresh(plugin_registry([{"rebar3_hex", &1}]))

    watch.(reviewed ++ ["9.0.0"])
    assert version(name) == nil
    refute Catalog.published_sha256?(sha)
    refute name in Catalog.packages_with_precompiled_files()

    watch.(reviewed)
    assert %{"builds_closure" => [_]} = version(name)
    assert Catalog.published_sha256?(sha)
  end

  # Review S5 S1: a pinned host build with no plugin record whose compile
  # fetched a plugin is rebuilt by no requeue: the sweep marks it.
  test "a pinned build with the plugin mark and no record is withheld by the sweep" do
    mark = %{"os_type_reads" => [%{"module" => "pubkey_os_cacerts", "function" => "on_load"}]}
    %{name: name, sha: sha} = ingested(observations: mark)
    %{name: plain} = ingested(observations: %{"os_type_reads" => []})
    Portal.Precompiled.PluginWatch.refresh(plugin_registry())
    assert %{"builds_closure" => [_]} = version(name)

    # From before os_type_reads, with a release in its lock that runs
    # rebar3_hex (mimerl 1.0.0, `PluginWatch.Declared`).
    old = unique()
    mimerl = [%{"name" => "mimerl", "hex" => "mimerl", "version" => "1.0.0", "checksum" => @b}]
    {:ok, _row} = ingest(old, pins(old, mimerl), observations: %{"problems" => []})
    assert %{"builds_closure" => [_]} = version(old)

    assert :ok = Portal.Precompiled.PluginWatch.mark_unrecorded()
    assert version(name) == nil
    refute Catalog.published_sha256?(sha)
    assert version(old) == nil
    assert %{"builds_closure" => [_]} = version(plain)
  end

  test "rule-2 revocation reaches a pinned build, the files route and the fingerprint follow" do
    %{name: name, sha: sha} = ingested()
    before = Catalog.precompiled_fingerprints()[name]
    assert before =~ "|pinned:"
    assert Catalog.published_sha256?(sha)

    assert {:dry_run, [%{kind: :pinned_build, variant: "pinned"}]} =
             ToolchainRevocation.revoke(package: name, everything: true)

    assert {:revoked, 1, [%{kind: :pinned_build}], at} =
             ToolchainRevocation.revoke(dry_run: false, package: name, everything: true)

    refute Catalog.published_sha256?(sha)
    assert version(name) == nil
    assert Catalog.precompiled_fingerprints()[name] != before
    assert {^at, 1} = List.last(ToolchainRevocation.revocations())

    assert {:ok, 1} = ToolchainRevocation.undo(at)
    assert Catalog.published_sha256?(sha)
  end

  test "revoke_run/1 revokes a pinned build by its run id" do
    %{name: name, row: row, sha: sha} = ingested()
    before = Catalog.precompiled_fingerprints()[name]

    assert {:ok, %Catalog.PinnedBuild{revoked_reason: "run revoked"}} =
             Catalog.revoke_run(row.run_id)

    refute Catalog.published_sha256?(sha)
    assert version(name) == nil
    assert Catalog.precompiled_fingerprints()[name] != before
  end

  test "a package without pinned builds keeps the fingerprint it had" do
    %{name: name} = ingested()
    other = unique()

    {:ok, _tb} =
      Portal.Catalog.Ingestion.ingest_toolchain(
        result(other, pins(other)) |> Map.put("requested_optional_deps", "include"),
        other
        |> opts(pins(other), files(["beam-" <> other]))
        |> Map.drop([:pins, :pin_hash, :target])
      )

    fingerprints = Catalog.precompiled_fingerprints()
    assert fingerprints[name] =~ "|pinned:"
    refute fingerprints[other] =~ "|pinned:"
  end

  # The publishing gate (`@served_pinned_clause`) reads the builder's row,
  # so the batch fingerprint must carry that row's state, as a run's does
  # (`Portal.Catalog.PublishingGateTest`), or a batch keeps serving a build
  # whose builder stopped publishing.
  test "the fingerprint follows the publishing flag of a pinned build's builder" do
    builder =
      Portal.Builders.Builder
      |> Ash.Changeset.for_create(:enrol, %{
        name: unique(),
        fingerprint: "fp-" <> unique(),
        cert_pem: "p",
        cert_expires_at: DateTime.utc_now(),
        enrolled_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    {:ok, builder} = Portal.Builders.set_publishing(builder, true)
    name = unique()
    pins = pins(name)

    {:ok, _row} =
      Catalog.Ingestion.ingest_pinned(
        result(name, pins),
        name |> opts(pins, files(["beam-" <> name])) |> Map.put(:builder_id, builder.id)
      )

    assert %{"builds_closure" => [_]} = version(name)
    before = Catalog.precompiled_fingerprints()[name]

    {:ok, _} = Portal.Builders.set_publishing(builder, false)
    assert version(name) == nil
    assert Catalog.precompiled_fingerprints()[name] != before
  end

  test "at most 8 closures of one version are listed" do
    name = unique()

    for i <- 1..9 do
      pins = pins(name, [dep("decimal", "2.3.#{i}")])
      {:ok, _} = ingest(name, pins, beams: ["beam-#{name}-#{i}"])
    end

    assert %{"builds_closure" => listed} = version(name)
    assert length(listed) == 8
    assert listed |> Enum.map(& &1["build"]["deps"]) |> Enum.uniq() |> length() == 8
  end

  test "a pinned build's sibling is served under deterministic.builds_closure and revocable" do
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})
    name = unique()
    pins = pins(name)
    {normal, sibling} = beam_pair(name)

    sibling_build =
      result(name, pins)["toolchain_build"]
      |> Map.merge(%{
        "erl_compiler_options" => ["deterministic"],
        "file_manifest" => %{"ebin" => [entry("ebin/m0.beam", sibling)], "priv" => []}
      })

    result = result(name, pins, beams: [normal], sibling: sibling_build)

    {:ok, _row} =
      Catalog.Ingestion.ingest_pinned(result, opts(name, pins, files([normal, sibling])))

    assert %{"deterministic" => %{"builds" => [], "builds_closure" => [entry]}} = version(name)
    assert entry["build"]["erl_compiler_options"] == ["deterministic"]
    assert Catalog.published_sha256?(sha(sibling))

    assert {:revoked, 1, [%{variant: "pinned"}], _at} =
             DeterministicRevocation.revoke(dry_run: false, package: name)

    refute Catalog.published_sha256?(sha(sibling))
    assert Catalog.published_sha256?(sha(normal))
  end

  # Phase 2: a pinned firmware build (`Portal.Pins.FirmwareBuild`).
  describe "a pinned firmware build" do
    defp ingested_firmware(opts \\ []) do
      name = unique()
      pins = pins(name)
      {:ok, row} = ingest_firmware(name, pins, opts)
      %{name: name, pins: pins, row: row, sha: sha("beam-" <> name)}
    end

    # Review focus 4: never under a list a client that does not compare the
    # env closure reads.
    test "is listed under builds_closure only, at its target and release" do
      %{name: name, row: row, sha: sha} = ingested_firmware()

      assert %{"builds" => [], "builds_closure" => [entry]} = version = version(name)
      refute Map.has_key?(version, "builds_with_inputs")
      assert entry["target"] == "nerves_system_rpi4"
      assert entry["build"]["system_version"] == "2.1.2"
      assert entry["build"]["mix_target"] == "rpi4"
      assert entry["build"]["deps"] == row.deps_lock
      assert entry["build"]["variant"] == "pinned"
      assert entry["build"]["elixir"] == "1.20.5" and entry["build"]["otp"] == "29"
      assert entry["build"]["run_id"] == row.run_id
      assert entry["build"]["compile_env"] == []
      assert [%{"path" => "ebin/m0.beam", "sha256" => ^sha}] = entry["ebin"]
      refute Map.has_key?(entry, :closure_only)

      assert Catalog.precompiled_manifest(name) == nil
      assert Catalog.published_sha256?(sha)
      assert name in Catalog.packages_with_precompiled_files()
      assert Catalog.precompiled_fingerprints()[name] =~ "|pinned:"
    end

    # Review focus 1: the client takes a build that says `native: false`, or
    # native and portable, on another release of the system; a pinned build
    # is served at its own release only.
    test "never carries native false or portable" do
      %{name: name, row: row} = ingested_firmware()
      assert row.native == false and row.portable == true

      assert %{"builds_closure" => [%{"build" => build}]} = version(name)

      for key <- ["native", "portable", "elf"],
          do: refute(Map.has_key?(build, key), key)

      assert build["otp_full"] == "29.0.6"

      assert build["toolchain"] == %{
               "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
               "version" => "15.3.1"
             }

      Portal.Repo.query!(
        "UPDATE catalog_pinned_builds SET native = true, portable = true, elf_needs = $2 " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(row.id), %{"libc.so.6" => ["GLIBC_2.17"]}]
      )

      assert %{"builds_closure" => [%{"build" => build}]} = version(name)
      assert build["native"] == true
      assert build["elf"] == %{"needs" => %{"libc.so.6" => ["GLIBC_2.17"]}}
      refute Map.has_key?(build, "portable")
    end

    test "a skipped one is not served" do
      %{name: name, sha: sha} = ingested_firmware(system_version: "2.2.0")
      assert version(name) == nil
      refute Catalog.published_sha256?(sha)
    end

    test "revoke_run/1 reaches it" do
      %{name: name, row: row, sha: sha} = ingested_firmware()

      assert {:ok, %Catalog.PinnedBuild{revoked_reason: "run revoked"}} =
               Catalog.revoke_run(row.run_id)

      assert version(name) == nil
      refute Catalog.published_sha256?(sha)
    end

    # The 8-closure cap counts per release: two releases of one target are
    # each their own key.
    test "two releases of one target are listed side by side" do
      name = unique()
      pins = pins(name)
      {:ok, _} = ingest_firmware(name, pins)

      {:ok, _} =
        ingest_firmware(name, pins,
          system_version: "2.2.0",
          beams: ["beam-#{name}-2"],
          job: [system_version: "2.2.0"]
        )

      assert %{"builds_closure" => listed} = version(name)

      assert listed |> Enum.map(& &1["build"]["system_version"]) |> Enum.sort() == [
               "2.1.2",
               "2.2.0"
             ]
    end
  end
end
