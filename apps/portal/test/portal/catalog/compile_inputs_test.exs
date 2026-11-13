defmodule Portal.Catalog.CompileInputsTest do
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import PortalWeb.ApiSpecAssertions

  alias Portal.Catalog
  alias Portal.Repo

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @unset :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  @host [%{"kind" => "env", "name" => "GITHUB_ACTIONS", "value" => @unset, "set_by" => "host"}]
  @own [
    %{
      "kind" => "env",
      "name" => "B",
      "value" => @unset,
      "set_by" => "build",
      "inputs" => "recorded"
    }
  ]

  defp name, do: "ci_tc_#{System.unique_integer([:positive])}"

  # The fixture run with the deps lock and package checksum format 2 requires.
  defp result_fixture do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}})
    |> Map.put("package_checksum", "outer")
  end

  test "a build that needs a check is stored and published under builds_with_inputs only" do
    name = name()
    tb = ingest_toolchain_build(name, "0.3.0", compile_inputs: @host)
    assert tb.compile_inputs == @host

    manifest = Catalog.precompiled_manifest_v2(name)
    assert %{"builds" => [], "builds_with_inputs" => [build]} = manifest["versions"]["0.3.0"]
    assert build["build"]["compile_inputs"] == @host
    assert_api_schema(manifest, "ManifestV2")
  end

  test "a build with a config_order item is published under builds_with_inputs" do
    name = name()

    order = [
      %{
        "kind" => "config_order",
        "app" => "fx",
        "path" => ["k"],
        "reader" => "r",
        "default" => @unset,
        "seen" => @unset
      }
    ]

    tb = ingest_toolchain_build(name, "0.3.0", compile_inputs: order)
    assert tb.compile_inputs == order
    manifest = Catalog.precompiled_manifest_v2(name)
    assert %{"builds" => [], "builds_with_inputs" => [_]} = manifest["versions"]["0.3.0"]
    assert_api_schema(manifest, "ManifestV2")
  end

  test "a build whose inputs need no check stays under builds, with the field" do
    name = name()
    ingest_toolchain_build(name, "0.3.0", compile_inputs: @own)
    version = Catalog.precompiled_manifest_v2(name)["versions"]["0.3.0"]
    assert [%{"build" => %{"compile_inputs" => @own}}] = version["builds"]
    refute Map.has_key?(version, "builds_with_inputs")
  end

  test "a build made before the field renders exactly as before" do
    name = name()
    ingest_toolchain_build(name, "0.3.0")
    [build] = Catalog.precompiled_manifest_v2(name)["versions"]["0.3.0"]["builds"]
    refute Map.has_key?(build["build"], "compile_inputs")
  end

  test "malformed inputs store none and drop compile_env, so nothing publishes" do
    for bad <- [[%{"kind" => "teleport"}], [%{"kind" => "env", "name" => "X"}], "nope"] do
      name = name()
      tb = ingest_toolchain_build(name, "0.3.0", compile_inputs: bad)
      assert tb.compile_inputs == nil and tb.compile_env == nil
      assert Catalog.precompiled_manifest_v2(name) == nil
    end
  end

  test "an unrecordable compile_env value is kept" do
    name = name()
    env = [%{"app" => "fx", "path" => ["k"], "value" => "unrecordable"}]
    tb = ingest_toolchain_build(name, "0.3.0", compile_env: env, compile_inputs: [])
    assert tb.compile_env == env
  end

  test "format 1 never lists a run result that needs a check" do
    result =
      result_fixture()
      |> put_in(["systems", "nerves_system_rpi4", "compile_inputs"], [%{"kind" => "env_all"}])
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

    ingest_with_artifact(result)
    name = result["package"]["name"]
    version = result["package"]["version"]
    %{v1: v1, v2: v2} = Catalog.precompiled_manifests(name)

    refute v1 && Map.has_key?(v1.versions[version] || %{}, "nerves_system_rpi4")

    assert Enum.any?(
             v2["versions"][version]["builds_with_inputs"] || [],
             &(&1["target"] == "nerves_system_rpi4")
           )

    refute Enum.any?(v2["versions"][version]["builds"], &(&1["target"] == "nerves_system_rpi4"))
  end

  test "a change to compile_inputs changes the package's fingerprint" do
    name = name()
    tb = ingest_toolchain_build(name, "0.3.0", compile_inputs: [])
    before = Catalog.precompiled_fingerprints()[name]

    Repo.query!(
      ~s(UPDATE catalog_toolchain_builds SET compile_inputs = ARRAY['{"kind":"env_all"}'::jsonb] WHERE id = $1),
      [Ecto.UUID.dump!(tb.id)]
    )

    refute Catalog.precompiled_fingerprints()[name] == before
  end
end
