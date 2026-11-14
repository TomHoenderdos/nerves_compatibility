defmodule Portal.Catalog.ManifestWorldTest do
  # A world build (`Compatibility.Worlds`) is served only in format 2's
  # `builds_closure` list, which only clients that check the whole env
  # closure read. A client before that never sees it: not in `builds`, not in
  # `builds_with_inputs`, not in format 1 and not in the signed batch beyond
  # the format-2 manifest's own hash.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import PortalWeb.ApiSpecAssertions

  alias Portal.Catalog

  @with_lock %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}}
  @world_lock %{
    "jason" => %{"version" => "1.4.4", "checksum" => "j"},
    "decimal" => %{"version" => "2.3.0", "checksum" => "d"}
  }
  @unset :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  @inputs [%{"kind" => "env", "name" => "GITHUB_ACTIONS", "value" => @unset, "set_by" => "host"}]

  defp name(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp revoke!(build),
    do: build |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)

  defp encode(manifest), do: Jason.encode!(manifest)

  test "a package with no world rows renders the bytes it always did" do
    name = name("plain")
    ingest_toolchain_build(name, "1.0.0", deps_lock: @with_lock)
    ingest_toolchain_build(name, "1.0.0", deps_lock: %{}, variant: :without)

    before = Catalog.precompiled_manifest_v2(name)
    bytes = encode(before)

    assert Map.keys(before["versions"]["1.0.0"]) == ["builds"]
    refute bytes =~ "builds_closure"
    refute bytes =~ ~s("variant")

    world = ingest_toolchain_build(name, "1.0.0", deps_lock: @world_lock, variant: :world_phx)
    assert world.status == :pass

    with_world = Catalog.precompiled_manifest_v2(name)
    assert with_world["versions"]["1.0.0"]["builds"] == before["versions"]["1.0.0"]["builds"]

    revoke!(world)
    assert encode(Catalog.precompiled_manifest_v2(name)) == bytes
  end

  test "a world build appears only in builds_closure, marked with its variant" do
    name = name("world")
    ingest_toolchain_build(name, "1.0.0", deps_lock: @with_lock)
    ingest_toolchain_build(name, "1.0.0", deps_lock: @world_lock, variant: :world_phx)

    manifest = Catalog.precompiled_manifest_v2(name)
    assert_api_schema(manifest, "ManifestV2")
    %{"versions" => %{"1.0.0" => version}} = manifest

    assert [%{"build" => with_build}] = version["builds"]
    assert with_build["deps"] == @with_lock
    refute Map.has_key?(with_build, "variant")
    refute Map.has_key?(version, "builds_with_inputs")

    assert [%{"target" => "pure_elixir", "build" => world_build}] = version["builds_closure"]
    assert world_build["deps"] == @world_lock
    assert world_build["variant"] == "world_phx"
  end

  test "a world build with inputs to check is still only in builds_closure" do
    name = name("inputs")

    ingest_toolchain_build(name, "1.0.0",
      deps_lock: @world_lock,
      variant: :world_phx,
      compile_inputs: @inputs
    )

    version = Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]

    assert version["builds"] == []
    refute Map.has_key?(version, "builds_with_inputs")
    assert [%{"build" => %{"compile_inputs" => [_]}}] = version["builds_closure"]
  end

  test "a version with only world builds still has an empty builds list" do
    name = name("only_world")
    ingest_toolchain_build(name, "1.0.0", deps_lock: @world_lock, variant: :world_phx)

    assert %{"versions" => %{"1.0.0" => %{"builds" => [], "builds_closure" => [_]}}} =
             Catalog.precompiled_manifest_v2(name)
  end

  @tag :tmp_dir
  test "format 1 and the signed batch never carry a world row", %{tmp_dir: dir} do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    key_path = Path.join(dir, "signing.key")
    Portal.Precompiled.Keys.write!(key_path, Portal.Precompiled.Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: key_path)

    name = name("batch")
    ingest_toolchain_build(name, "1.0.0", deps_lock: @world_lock, variant: :world_phx)

    assert Catalog.precompiled_manifest(name) == nil
    assert %{v1: nil, v2: %{} = v2} = Catalog.precompiled_manifests(name)
    assert [_] = v2["versions"]["1.0.0"]["builds_closure"]

    {:ok, batch} = Portal.Precompiled.Batches.build_and_sign()

    refute batch.payload =~ "world_phx"
    refute batch.payload =~ "builds_closure"
    refute Map.has_key?(Portal.Precompiled.Batches.manifests(batch), name)
  end

  test "the newest world build per closure is picked within builds_closure" do
    name = name("newest")

    ingest_toolchain_build(name, "1.0.0",
      deps_lock: @world_lock,
      variant: :world_phx,
      finished_at: "2026-10-24T10:00:00Z"
    )

    ingest_toolchain_build(name, "1.0.0",
      deps_lock: @world_lock,
      variant: :world_phx,
      builder_version: 2,
      finished_at: "2026-11-01T10:00:00Z"
    )

    assert [%{"build" => build}] =
             Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]["builds_closure"]

    assert build["run_id"] != nil
  end
end
