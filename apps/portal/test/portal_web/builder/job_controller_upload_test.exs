defmodule PortalWeb.Builder.JobControllerUploadTest do
  use PortalWeb.BuilderConnCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Builders.{Lease, Leases, Upload}

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :root, root))
    Application.put_env(:portal, Leases, long_poll_ms: 50)

    # The free-space floor is a host property; tests that need it set their own.
    builder_config = Application.get_env(:portal, Portal.Builder, [])

    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.put(builder_config, :min_free_disk_gb, 0)
    )

    on_exit(fn ->
      Application.put_env(:portal, Upload, previous)
      Application.put_env(:portal, Portal.Builder, builder_config)
      Application.delete_env(:portal, Leases)
      File.rm_rf(root)
    end)

    %{builder: builder, cert_der: der} = enrolled_builder!("u1")

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    {:ok, _lease} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.4",
        image_name: "i",
        image_digest: "sha256:#{String.duplicate("c", 64)}",
        args: %{},
        scan_request_id: request.id,
        priority: 5
      })

    {:ok, lease} = Leases.claim(builder)
    %{der: der, lease: lease, builder: builder, request: request}
  end

  defp sha(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "ctar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    files =
      for {name, bytes} <- entries do
        File.write!(Path.join(dir, name), bytes)
        {String.to_charlist(name), String.to_charlist(Path.join(dir, name))}
      end

    :ok = :erl_tar.create(String.to_charlist(Path.join(dir, "b.tar")), files)
    bin = File.read!(Path.join(dir, "b.tar"))
    File.rm_rf!(dir)
    bin
  end

  defp put_tar(conn, der, lease_id, bin) do
    conn
    |> with_cert(der)
    |> put_req_header("content-type", "application/x-tar")
    |> put_req_header("content-length", Integer.to_string(byte_size(bin)))
    |> put("/builder/v1/jobs/#{lease_id}/files", bin)
  end

  test "missing, upload and complete hand the run to Ingest on the remote queue",
       %{conn: conn, der: der, lease: lease, builder: builder} do
    good = sha("beam")

    assert %{"missing" => [^good]} =
             conn
             |> with_cert(der)
             |> post("/builder/v1/jobs/#{lease.id}/files/missing", %{"shas" => [good]})
             |> json_response(200)

    assert %{"stored" => [^good], "bad" => []} =
             put_tar(conn, der, lease.id, tar([{good, "beam"}])) |> json_response(200)

    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).state == :uploading

    result =
      Jason.encode!(%{
        "run_id" => lease.run_id,
        "package" => %{"name" => "jason", "version" => "1.4.4"},
        "systems" => %{"host" => %{"status" => "pass"}}
      })

    result_path =
      Path.join(System.tmp_dir!(), "result-#{System.unique_integer([:positive])}.json")

    File.write!(result_path, result)

    conn =
      conn
      |> with_cert(der)
      |> post("/builder/v1/jobs/#{lease.id}/complete", %{
        "exit_code" => "0",
        "result" => %Plug.Upload{
          path: result_path,
          filename: "result.json",
          content_type: "application/json"
        }
      })

    assert %{"accepted" => true, "outcome" => "done", "warm" => []} = json_response(conn, 202)

    assert [job] = all_enqueued(worker: Portal.Workers.Ingest)
    assert job.queue == "remote"
    assert job.args["source"] == "remote"
    assert job.args["lease_id"] == lease.id
    assert job.args["builder_id"] == builder.id
    assert job.args["run_id"] == lease.run_id
    assert File.exists?(Path.join(Upload.out_dir(lease.id), "result.json"))
  end

  # The builder warms its own Nerves cache only with what the portal names:
  # `Portal.NervesCache.warm_pairs/2` over the uploaded result.json, so a
  # miss the lock does not name, or a package the `nerves` Hex user does not
  # own, never comes back.
  test "a done completion names the warm pairs the portal's rule allows",
       %{conn: conn, der: der, lease: lease} do
    previous = Application.get_env(:portal, Portal.NervesCache)

    Application.put_env(:portal, Portal.NervesCache,
      owners: fn
        "nerves_system_rpi4" -> {:ok, ["nerves", "fhunleth"]}
        _other -> {:ok, ["mallory"]}
      end
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, Portal.NervesCache, previous),
        else: Application.delete_env(:portal, Portal.NervesCache)
    end)

    rpi4 = %{"name" => "nerves_system_rpi4", "version" => "1.30.0"}
    forged = %{"name" => "nerves_system_rpi0", "version" => "1.30.0"}
    unowned = %{"name" => "nerves_system_mallory", "version" => "1.0.0"}

    result =
      Jason.encode!(%{
        "run_id" => lease.run_id,
        "package" => %{"name" => "jason", "version" => "1.4.4"},
        "systems" => %{"host" => %{"status" => "pass"}},
        "nerves_cache" => %{
          "misses" => [rpi4, forged, unowned],
          "lock" => [rpi4, unowned]
        }
      })

    result_path =
      Path.join(System.tmp_dir!(), "result-#{System.unique_integer([:positive])}.json")

    File.write!(result_path, result)

    body =
      conn
      |> with_cert(der)
      |> post("/builder/v1/jobs/#{lease.id}/complete", %{
        "exit_code" => "0",
        "result" => %Plug.Upload{
          path: result_path,
          filename: "result.json",
          content_type: "application/json"
        }
      })
      |> json_response(202)

    assert body["outcome"] == "done"
    assert body["warm"] == [rpi4]
  end

  defp result_upload(map) do
    path = Path.join(System.tmp_dir!(), "result-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(map))
    %Plug.Upload{path: path, filename: "result.json", content_type: "application/json"}
  end

  # A builder may produce bad results for the package it was leased, never
  # for another one: `Ingestion` takes the package from result.json.
  test "a result.json for another package or version is refused and the lease stays held",
       %{conn: conn, der: der, lease: lease} do
    for package <- [
          %{"name" => "phoenix", "version" => "1.4.4"},
          %{"name" => "jason", "version" => "1.4.3"},
          %{}
        ] do
      result = %{"run_id" => lease.run_id, "package" => package, "systems" => %{}}

      assert %{"error" => "result_mismatch"} =
               conn
               |> with_cert(der)
               |> post("/builder/v1/jobs/#{lease.id}/complete", %{
                 "exit_code" => "0",
                 "result" => result_upload(result)
               })
               |> json_response(422)
    end

    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).state == :uploading
    assert [] = all_enqueued(worker: Portal.Workers.Ingest)
  end

  test "a failing exit's runner log reaches the request once the lease fails",
       %{conn: conn, der: der, lease: lease, builder: builder, request: request} do
    log = Path.join(System.tmp_dir!(), "runner-#{System.unique_integer([:positive])}.log")
    File.write!(log, "the compiler said no\n")
    part = %Plug.Upload{path: log, filename: "runner.log", content_type: "text/plain"}

    # Two attempts fail and requeue; the third fails the lease.
    lease =
      Enum.reduce(1..2, lease, fn _n, lease ->
        assert %{"outcome" => "requeued"} =
                 conn
                 |> with_cert(der)
                 |> post("/builder/v1/jobs/#{lease.id}/complete", %{
                   "exit_code" => "10",
                   "runner_log" => part
                 })
                 |> json_response(202)

        {:ok, lease} = Leases.claim(builder)
        lease
      end)

    assert %{"outcome" => "failed"} =
             conn
             |> with_cert(der)
             |> post("/builder/v1/jobs/#{lease.id}/complete", %{
               "exit_code" => "10",
               "runner_log" => part
             })
             |> json_response(202)

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :error
    assert updated.error_log =~ "the compiler said no"
  end

  test "a lease may not hold more than max_files entries", %{conn: conn, der: der, lease: lease} do
    previous = Application.get_env(:portal, Upload, [])
    Application.put_env(:portal, Upload, Keyword.put(previous, :max_files, 2))
    on_exit(fn -> Application.put_env(:portal, Upload, previous) end)

    entries = for i <- 1..3, do: {sha("f#{i}"), "f#{i}"}

    # The batch is refused at its third entry; the two verified entries
    # before it stay, as with any refusal after a stored entry.
    assert %{"error" => "too_many_files"} =
             put_tar(conn, der, lease.id, tar(entries)) |> json_response(422)

    assert length(File.ls!(Upload.files_dir(lease.id))) == 2

    [_a, _b, c] = entries

    assert %{"error" => "too_many_files"} =
             put_tar(conn, der, lease.id, tar([c])) |> json_response(422)

    assert length(File.ls!(Upload.files_dir(lease.id))) == 2
  end

  test "a bad entry answers 422 and keeps the good one", %{conn: conn, der: der, lease: lease} do
    good = sha("g")
    bad = sha("b")

    assert %{"error" => "bad_entries", "bad" => [^bad]} =
             put_tar(conn, der, lease.id, tar([{good, "g"}, {bad, "x"}])) |> json_response(422)

    assert File.exists?(Path.join(Upload.files_dir(lease.id), good))
  end

  test "a PUT without a content length answers 400", %{conn: conn, der: der, lease: lease} do
    assert %{"error" => "missing_content_length"} =
             conn
             |> with_cert(der)
             |> put_req_header("content-type", "application/x-tar")
             |> put("/builder/v1/jobs/#{lease.id}/files", "")
             |> json_response(400)
  end

  test "another builder gets 409 everywhere", %{conn: conn, lease: lease} do
    %{cert_der: other} = enrolled_builder!("u2")

    assert conn
           |> with_cert(other)
           |> post("/builder/v1/jobs/#{lease.id}/files/missing", %{"shas" => []})
           |> json_response(409)

    assert put_tar(conn, other, lease.id, tar([])) |> json_response(409)

    assert conn
           |> with_cert(other)
           |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "0"})
           |> json_response(409)
  end

  test "a failing exit requeues and keeps the files; a policy exit rejects and cleans up",
       %{conn: conn, der: der, lease: lease, builder: builder, request: request} do
    File.mkdir_p!(Upload.files_dir(lease.id))

    assert %{"outcome" => "requeued"} =
             conn
             |> with_cert(der)
             |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "10"})
             |> json_response(202)

    # The next attempt's `files/missing` skips what already landed.
    assert File.exists?(Upload.files_dir(lease.id))
    assert [] = all_enqueued(worker: Portal.Workers.Ingest)

    {:ok, lease} = Leases.claim(builder)

    assert %{"outcome" => "rejected"} =
             conn
             |> with_cert(der)
             |> post("/builder/v1/jobs/#{lease.id}/complete", %{"exit_code" => "11"})
             |> json_response(202)

    refute File.exists?(Upload.lease_dir(lease.id))

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :rejected
  end
end
