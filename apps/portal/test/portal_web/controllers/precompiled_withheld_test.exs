defmodule PortalWeb.PrecompiledWithheldTest do
  # The per-name manifest routes and the file route apply
  # `Portal.Precompiled.Withheld` like the batch does, with and without a
  # signed batch.
  use PortalWeb.ConnCase, async: false

  alias Portal.Precompiled.{Batches, Keys}

  import Portal.PrecompiledFixtures

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @run_sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
  @decimal %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @liveview Map.put(@decimal, "phoenix_live_view", %{"version" => "1.1.0", "checksum" => "def"})

  defp run(deps_lock) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", deps_lock)
    |> Map.put("package_checksum", "outer")
    |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])
  end

  defp signing_key!(dir) do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    key_path = Path.join(dir, "signing.key")
    Keys.write!(key_path, Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: key_path)
  end

  defp assert_withheld(conn, name, shas) do
    assert conn |> get("/api/precompiled/manifests/#{name}.json") |> json_response(404)
    assert conn |> get("/api/precompiled/v2/manifests/#{name}.json") |> json_response(404)

    for sha <- shas do
      assert get(conn, "/api/precompiled/files/#{sha}").status == 404
    end
  end

  # A lock naming phoenix_live_view, and no lock at all (format 1's
  # `"deps": null`, an unknown closure), on a full run and a toolchain build.
  for {label, lock} <- [{"a phoenix_live_view lock", @liveview}, {"no lock", nil}] do
    @tag lock: lock
    test "a full run with #{label} is not served by name or by file", %{conn: conn, lock: lock} do
      ingest_with_artifact(run(lock))
      assert_withheld(conn, "jason", [@run_sha])
    end

    @tag lock: lock
    @tag :tmp_dir
    test "a full run with #{label} is not served by name once a batch is signed", %{
      conn: conn,
      lock: lock,
      tmp_dir: dir
    } do
      signing_key!(dir)
      ingest_with_artifact(run(lock))
      {:ok, batch} = Batches.build_and_sign()

      refute Map.has_key?(Batches.manifests(batch), "jason")
      refute Map.has_key?(Batches.manifests_v2(batch), "jason")
      assert_withheld(conn, "jason", [@run_sha])
    end

    @tag lock: lock
    test "a toolchain build with #{label} is not served by name or by file", %{
      conn: conn,
      lock: lock
    } do
      name = "tc_#{System.unique_integer([:positive])}"
      build = ingest_toolchain_build(name, "0.1.0", deps_lock: lock)
      assert_withheld(conn, name, [hd(build.file_manifest["ebin"])["sha256"]])
    end
  end

  test "a full run with a clean lock is served by name in both formats", %{conn: conn} do
    ingest_with_artifact(run(@decimal))

    assert %{"versions" => %{"1.4.1" => _}} =
             conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)

    assert %{"versions" => %{"1.4.1" => %{"builds" => [_]}}} =
             conn |> get("/api/precompiled/v2/manifests/jason.json") |> json_response(200)

    assert get(conn, "/api/precompiled/files/#{@run_sha}").status == 200
  end
end
