defmodule Portal.PinnedManifestTest do
  # Pinned builds are served only under a version's `builds_closure`, under
  # the lock they were built with, and every lever that withdraws a build,
  # the files route and the batch fingerprint cover them.
  use Portal.DataCase, async: false

  import Portal.PinnedFixtures

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
end
