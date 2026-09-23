defmodule PortalWeb.CatalogApiControllerTest do
  use PortalWeb.ConnCase, async: false

  alias Portal.Catalog.Ingestion
  alias Portal.ArtifactStore

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp ingest_fixture do
    dir = Path.join(System.tmp_dir!(), "catalog-api-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = @fixture |> File.read!() |> Jason.decode!()

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: "catalog-api-jason-1.4.1",
        image_digest: "sha256:api",
        files_dir: dir,
        scan_request_id: nil,
        log: "api log"
      })

    :ok
  end

  defp result_fixture, do: @fixture |> File.read!() |> Jason.decode!()

  test "unknown badge names are escaped as XML text", %{conn: conn} do
    name = "</title><script>window.badge_marker=1</script><title>&"
    path = "/badge/" <> URI.encode(name, &URI.char_unreserved?/1)
    conn = get(conn, path)
    body = response(conn, 404)

    assert get_resp_header(conn, "content-type") == ["image/svg+xml; charset=utf-8"]

    assert body =~
             "&lt;/title&gt;&lt;script&gt;window.badge_marker=1&lt;/script&gt;&lt;title&gt;&amp;"

    refute body =~ "<script>"
  end

  defp ingest_fixture_with_artifact do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    result = @fixture |> File.read!() |> Jason.decode!()

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: "catalog-api-precompiled-jason-1.4.1",
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "api log"
      })

    sha
  end

  test "GET /api/packages returns schema-v2 latest_by_pkg shape", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/api/packages")
    body = json_response(conn, 200)

    assert body["schema"] == 2
    assert is_binary(body["generated_at"])
    assert %{"jason" => jason} = body["packages"]
    assert jason["description"] == "A blazing fast JSON parser and generator in pure Elixir."
    assert jason["latest_version"] == "1.4.1"
    assert %{"nerves_system_rpi4@1.24.0" => rpi4} = jason["systems"]
    assert rpi4["status"] == "pass"
    assert rpi4["run_id"] == "catalog-api-jason-1.4.1"
  end

  test "GET /api/packages/:name returns one package in the same schema-v2 shape", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/api/packages/jason")
    body = json_response(conn, 200)

    assert body["schema"] == 2
    assert Map.keys(body["packages"]) == ["jason"]
  end

  test "GET /api/stats returns schema-v2 aggregate counts", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/api/stats")
    body = json_response(conn, 200)

    assert body["schema"] == 2
    assert body["counts"]["total"] == 3
    assert body["counts"]["pass"] == 2
    assert body["counts"]["fail"] == 1
    assert body["by_system"]["nerves_system_x86_64@1.24.0"]["fail"] == 1
    assert is_binary(body["last_run_finished_at"])
  end

  test "GET /badge/:name.svg returns an SVG badge from latest system results", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/badge/jason.svg")

    assert response_content_type(conn, :svg) =~ "image/svg+xml"
    body = response(conn, 200)
    assert body =~ ~s(<svg)
    assert body =~ "jason Nerves compatibility"
    assert body =~ "2/3 passing"
  end

  # The badge is embedded in other people's READMEs, so it is fetched once per
  # reader of those pages rather than by a client polling for fresh data. The
  # JSON endpoints keep their minute; this one is pinned separately because the
  # two have opposite traffic shapes and a shared helper would silently couple
  # them.
  test "GET /badge/:name.svg is cached for an hour, not a minute", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/badge/jason.svg")

    assert ["public, max-age=3600" <> _] = get_resp_header(conn, "cache-control")
  end

  test "the JSON API is still cached by the minute", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/api/packages/jason")

    assert ["public, max-age=60"] = get_resp_header(conn, "cache-control")
  end

  test "GET /api/precompiled/manifests/:package.json returns precompiled manifest", %{conn: conn} do
    sha = ingest_fixture_with_artifact()

    conn = get(conn, "/api/precompiled/manifests/jason.json")
    body = json_response(conn, 200)

    assert is_binary(body["updated_at"])
    assert %{"1.4.1" => version} = body["versions"]
    assert %{"nerves_system_rpi4" => rpi4} = version
    assert [%{"path" => "ebin/jason.beam", "sha256" => ^sha}] = rpi4["ebin"]
    assert rpi4["priv"] == []
  end

  # The bug this guards: a `.beam` is routinely byte-identical across targets,
  # and `catalog_artifacts` is keyed by sha alone. When ownership lived on that
  # table, the second system to be ingested recorded nothing and published an
  # empty manifest. Measured on production before the fix, that was 72% of all
  # stored manifest entries.
  #
  # Non-vacuity: both systems must list the file. Reverting the membership
  # lookup in `Portal.Catalog.manifest_shas_for_system_results/1` leaves
  # whichever system ingested second with `ebin == []`.
  test "a blob shared by two systems is published for both", %{conn: conn} do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-shared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["systems", "nerves_system_x86_64"], fn sys ->
        sys
        |> Map.put("status", "pass")
        |> Map.put(
          "beam_scan",
          get_in(result_fixture(), ["systems", "nerves_system_rpi4", "beam_scan"])
        )
      end)

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: "catalog-api-shared-jason-1.4.1",
        image_digest: "sha256:shared",
        files_dir: dir,
        scan_request_id: nil,
        log: "api log"
      })

    body =
      conn
      |> get("/api/precompiled/manifests/jason.json")
      |> json_response(200)

    assert %{"1.4.1" => version} = body["versions"]

    for system <- ["nerves_system_rpi4", "nerves_system_x86_64"] do
      assert %{^system => manifest} = version
      assert [%{"path" => "ebin/jason.beam", "sha256" => ^sha}] = manifest["ebin"]
    end
  end

  test "GET /api/precompiled/files/:sha256 serves artifact blob", %{conn: conn} do
    sha = ingest_fixture_with_artifact()

    conn = get(conn, "/api/precompiled/files/#{sha}")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/octet-stream"
    assert response(conn, 200) == "precompiled-beam"
  end

  test "artifact download refuses symlinks", %{conn: conn} do
    sha = ingest_fixture_with_artifact()
    path = ArtifactStore.blob_path(sha)
    target = path <> ".target"
    File.rename!(path, target)
    File.ln_s!(target, path)

    on_exit(fn ->
      File.rm(path)
      File.rm(target)
    end)

    assert conn |> get("/api/precompiled/files/#{sha}") |> response(404) == "Not Found"
  end

  test "invalid blob names return 404", %{conn: conn} do
    assert conn |> get("/api/precompiled/files/not-a-digest") |> response(404) == "Not Found"
  end

  test "browser pages restrict embedding and base URL changes", %{conn: conn} do
    conn = get(conn, "/packages")
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "base-uri 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'self'"
  end
end
