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

  defp ingest_fixture_with_artifact do
    sha = "aaaa000000000000000000000000000000000000000000000000000000000001"
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

  test "GET /api/precompiled/files/:sha256 serves artifact blob", %{conn: conn} do
    sha = ingest_fixture_with_artifact()

    conn = get(conn, "/api/precompiled/files/#{sha}")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/octet-stream"
    assert response(conn, 200) == "precompiled-beam"
  end
end
