defmodule PortalWeb.CatalogApiControllerTest do
  use PortalWeb.ConnCase, async: false

  alias Portal.Catalog.Ingestion
  alias Portal.ArtifactStore

  import Portal.PrecompiledFixtures

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

  defp ingest_fixture_with_artifact(result \\ result_fixture()) do
    _result = ingest_with_artifact(result)
    "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
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

  test "GET /api/stats does not list assessments as systems", %{conn: conn} do
    ingest_fixture()
    {:ok, _run} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.2.0", nil)

    body = conn |> get("/api/stats") |> json_response(200)

    systems = body["by_system"] |> Map.keys() |> Enum.map(&(&1 |> String.split("@") |> hd()))
    refute "registry_deps" in systems
    assert "nerves_system_x86_64" in systems
    # The global counts still include it: it is a result, just not a system.
    assert body["counts"]["total"] == 4
  end

  test "GET /badge/:name.svg returns an SVG badge from latest system results", %{conn: conn} do
    ingest_fixture()

    conn = get(conn, "/badge/jason.svg")

    assert response_content_type(conn, :svg) =~ "image/svg+xml"
    body = response(conn, 200)
    assert body =~ ~s(<svg)
    assert body =~ "jason Nerves compatibility"
    assert body =~ ">compatibility issues<"
    assert body =~ "#eab308"
    refute body =~ "passing"
  end

  test "GET /badge/:name.svg shows a registry-assessed package as compatible", %{conn: conn} do
    {:ok, _run} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.2.0", nil)

    conn = get(conn, "/badge/tiny_pure.svg")

    body = response(conn, 200)
    assert body =~ ">compatible<"
    assert body =~ "#22c55e"
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

  # A client may use an entry only when it was built with exactly its own
  # Elixir, OTP and Nerves system, so each entry names them, and the run and
  # image that produced it.
  test "each manifest entry says what it was built with", %{conn: conn} do
    ingest_fixture_with_artifact()

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    rpi4 = body["versions"]["1.4.1"]["nerves_system_rpi4"]

    assert rpi4["build"] == %{
             "elixir" => "1.16.0",
             "otp" => "26",
             "system_version" => "1.24.0",
             "run_id" => "catalog-api-precompiled-jason-1.4.1",
             "image_digest" => "sha256:precompiled",
             "deps" => nil,
             "compile_env" => nil,
             "package_checksum" => nil
           }
  end

  test "the build block publishes compile_env and package_checksum", %{conn: conn} do
    result =
      result_fixture()
      |> Map.put("package_checksum", "deadbeef")
      |> update_in(["systems", "nerves_system_rpi4"], fn sys ->
        Map.put(sys, "compile_env", [
          %{"app" => "sample", "path" => ["mode"], "value" => "g2gCZAACb2tkAARmYXN0"}
        ])
      end)

    ingest_fixture_with_artifact(result)

    body =
      conn
      |> get("/api/precompiled/manifests/#{result["package"]["name"]}.json")
      |> json_response(200)

    build =
      get_in(body, ["versions", result["package"]["version"], "nerves_system_rpi4", "build"])

    assert build["package_checksum"] == "deadbeef"

    assert build["compile_env"] == [
             %{"app" => "sample", "path" => ["mode"], "value" => "g2gCZAACb2tkAARmYXN0"}
           ]
  end

  test "a malformed compile_env entry stores none for that system", %{conn: conn} do
    result =
      result_fixture()
      |> update_in(
        ["systems", "nerves_system_rpi4"],
        &Map.put(&1, "compile_env", [%{"app" => 1}])
      )

    ingest_fixture_with_artifact(result)

    body =
      conn
      |> get("/api/precompiled/manifests/#{result["package"]["name"]}.json")
      |> json_response(200)

    assert get_in(body, [
             "versions",
             result["package"]["version"],
             "nerves_system_rpi4",
             "build",
             "compile_env"
           ]) == nil
  end

  # Dependencies' macros are expanded into the package's BEAMs, so an entry is
  # only reusable against the exact dependency tree it was built with.
  test "each manifest entry names the dependency lock it was built against", %{conn: conn} do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-deps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    deps_lock = %{"decimal" => %{"version" => "2.3.0", "checksum" => "abc"}}

    {:ok, _} =
      Ingestion.ingest(Map.put(result_fixture(), "deps_lock", deps_lock), %{
        run_id: "deps",
        image_digest: "sha256:deps",
        files_dir: dir,
        log: "l"
      })

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    assert body["versions"]["1.4.1"]["nerves_system_rpi4"]["build"]["deps"] == deps_lock
  end

  # A partial run copies the systems it did not rebuild from the previous run.
  # Those files were built by that earlier run, under its toolchain, image and
  # dependency lock, so the entry has to describe that run and not the one that
  # carried it.
  test "a carried-forward entry describes the run that built it", %{conn: conn} do
    old_sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    new_sha = :crypto.hash(:sha256, "x86-beam") |> Base.encode16(case: :lower)
    old_lock = %{"decimal" => %{"version" => "2.3.0", "checksum" => "old"}}
    new_lock = %{"decimal" => %{"version" => "2.3.1", "checksum" => "new"}}

    for sha <- [old_sha, new_sha] do
      _ = File.rm(ArtifactStore.blob_path(sha))
    end

    first =
      result_fixture()
      |> Map.merge(%{"finished_at" => "2026-01-01T00:00:00Z", "deps_lock" => old_lock})

    second =
      result_fixture()
      |> Map.merge(%{
        "finished_at" => "2026-06-01T00:00:00Z",
        "scope" => "targets",
        "deps_lock" => new_lock,
        "toolchain" => %{"elixir" => "1.18.4", "erlang" => "27"}
      })
      |> Map.put("systems", %{
        "nerves_system_x86_64" =>
          result_fixture()["systems"]["nerves_system_rpi4"]
          |> put_in(
            ["beam_scan", "footprint", "file_manifest", "ebin"],
            [%{"path" => "ebin/jason.beam", "sha256" => new_sha}]
          )
      })

    for {run_id, digest, result, sha, bytes} <- [
          {"builder", "sha256:first", first, old_sha, "precompiled-beam"},
          {"carrier", "sha256:second", second, new_sha, "x86-beam"}
        ] do
      dir =
        Path.join(System.tmp_dir!(), "catalog-api-carry-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, sha), bytes)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, _} =
        Ingestion.ingest(result, %{
          run_id: run_id,
          image_digest: digest,
          files_dir: dir,
          log: "l"
        })
    end

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    version = body["versions"]["1.4.1"]

    assert version["nerves_system_rpi4"]["build"] == %{
             "elixir" => "1.16.0",
             "otp" => "26",
             "system_version" => "1.24.0",
             "run_id" => "builder",
             "image_digest" => "sha256:first",
             "deps" => old_lock,
             "compile_env" => nil,
             "package_checksum" => nil
           }

    assert version["nerves_system_x86_64"]["build"]["run_id"] == "carrier"
    assert version["nerves_system_x86_64"]["build"]["elixir"] == "1.18.4"
    assert version["nerves_system_x86_64"]["build"]["deps"] == new_lock
  end

  # Runs are read newest first; merging each older one over the result made
  # the oldest build of a version win.
  test "a version is published from its newest run", %{conn: conn} do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))

    for {run_id, finished_at} <- [
          {"old-run", "2026-01-01T00:00:00Z"},
          {"new-run", "2026-06-01T00:00:00Z"}
        ] do
      dir =
        Path.join(System.tmp_dir!(), "catalog-api-order-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, sha), "precompiled-beam")
      on_exit(fn -> File.rm_rf(dir) end)

      result = result_fixture() |> Map.put("finished_at", finished_at)

      {:ok, _} =
        Ingestion.ingest(result, %{
          run_id: run_id,
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        })
    end

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    assert body["versions"]["1.4.1"]["nerves_system_rpi4"]["build"]["run_id"] == "new-run"
  end

  # Builders ingest into the shared database but keep blobs in their own
  # store; the web host pulls them minutes later. Until then the file endpoint
  # answers 404, and a client given the entry would install a partial package.
  test "an entry whose blob is not in this host's store is not published", %{conn: conn} do
    sha = ingest_fixture_with_artifact()
    File.rm!(ArtifactStore.blob_path(sha))

    assert conn |> get("/api/precompiled/files/#{sha}") |> response(404)
    assert conn |> get("/api/precompiled/manifests/jason.json") |> json_response(404)
  end

  # A partial entry is worse than none, so one missing file drops the whole
  # entry rather than just that file.
  test "an entry with one of its files missing is not published", %{conn: conn} do
    here = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    pending = :crypto.hash(:sha256, "pending-beam") |> Base.encode16(case: :lower)

    dir =
      Path.join(System.tmp_dir!(), "catalog-api-partial-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for {sha, bytes} <- [{here, "precompiled-beam"}, {pending, "pending-beam"}] do
      _ = File.rm(ArtifactStore.blob_path(sha))
      File.write!(Path.join(dir, sha), bytes)
    end

    result =
      put_in(
        result_fixture(),
        ["systems", "nerves_system_rpi4", "beam_scan", "footprint", "file_manifest", "ebin"],
        [
          %{"path" => "ebin/jason.beam", "sha256" => here},
          %{"path" => "ebin/Elixir.Jason.Pending.beam", "sha256" => pending}
        ]
      )

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "partial",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "l"
      })

    File.rm!(ArtifactStore.blob_path(pending))

    assert conn |> get("/api/precompiled/manifests/jason.json") |> json_response(404)
  end

  # Non-vacuity: the two runs must not share a blob, or deleting the newer
  # one's file would take the older entry down with it.
  test "a version falls back to its newest run whose files are all here", %{conn: conn} do
    old_sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    new_sha = :crypto.hash(:sha256, "newer-beam") |> Base.encode16(case: :lower)

    for {run_id, finished_at, sha, bytes} <- [
          {"old-run", "2026-01-01T00:00:00Z", old_sha, "precompiled-beam"},
          {"new-run", "2026-06-01T00:00:00Z", new_sha, "newer-beam"}
        ] do
      _ = File.rm(ArtifactStore.blob_path(sha))

      dir =
        Path.join(System.tmp_dir!(), "catalog-api-pending-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, sha), bytes)
      on_exit(fn -> File.rm_rf(dir) end)

      result =
        result_fixture()
        |> Map.put("finished_at", finished_at)
        |> put_in(
          ["systems", "nerves_system_rpi4", "beam_scan", "footprint", "file_manifest", "ebin"],
          [%{"path" => "ebin/jason.beam", "sha256" => sha}]
        )

      {:ok, _} =
        Ingestion.ingest(result, %{
          run_id: run_id,
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        })
    end

    File.rm!(ArtifactStore.blob_path(new_sha))

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    rpi4 = body["versions"]["1.4.1"]["nerves_system_rpi4"]
    assert rpi4["build"]["run_id"] == "old-run"
    assert [%{"sha256" => ^old_sha}] = rpi4["ebin"]
  end

  # `path` and `mode` come from JSON the build container wrote, so a package
  # under test controls them. A client writes files at `path` with `mode`.
  test "entries with unsafe paths or modes are not published", %{conn: conn} do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-unsafe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    entries = [
      %{"path" => "ebin/jason.beam", "sha256" => sha, "mode" => 0o100644},
      %{"path" => "ebin/../../evil.beam", "sha256" => sha, "mode" => 0o100644},
      %{"path" => "/etc/evil", "sha256" => sha, "mode" => 0o100644},
      %{"path" => "lib/elsewhere.beam", "sha256" => sha, "mode" => 0o100644},
      %{"path" => "priv/suid.so", "sha256" => sha, "mode" => 0o104755}
    ]

    result =
      put_in(
        result_fixture(),
        ["systems", "nerves_system_rpi4", "beam_scan", "footprint", "file_manifest", "ebin"],
        entries
      )

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "unsafe",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "l"
      })

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    paths = Enum.map(body["versions"]["1.4.1"]["nerves_system_rpi4"]["ebin"], & &1["path"])
    assert paths == ["ebin/jason.beam"]
  end

  # A pure Elixir package builds no firmware; its host-built files fit every
  # target and are published under `pure_elixir`, which clients fall back to.
  test "a pure Elixir run publishes its host-built files under pure_elixir", %{conn: conn} do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-pure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    fixture = result_fixture()
    pure = Map.put(fixture["systems"]["nerves_system_rpi4"], "system_version", nil)

    result =
      Map.put(fixture, "systems", %{
        "host" => fixture["systems"]["host"],
        "pure_elixir" => pure
      })

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "pure",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "l"
      })

    body = conn |> get("/api/precompiled/manifests/jason.json") |> json_response(200)
    assert %{"pure_elixir" => entry} = body["versions"]["1.4.1"]
    assert [%{"path" => "ebin/jason.beam", "sha256" => ^sha}] = entry["ebin"]
    assert entry["build"]["elixir"] == "1.16.0"
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
