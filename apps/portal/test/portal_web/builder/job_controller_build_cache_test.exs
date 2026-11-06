defmodule PortalWeb.Builder.JobControllerBuildCacheTest do
  use PortalWeb.BuilderConnCase, async: false

  import ExUnit.CaptureLog

  alias Compatibility.BuildCache.Tarball
  alias Portal.BuildCache.L2
  alias Portal.Builders.{Lease, Leases, RateLimit}
  alias Portal.Test.FakeS3

  @hex String.duplicate("c", 64)
  @digest "sha256:" <> @hex
  @slug "sha256_" <> @hex

  setup do
    Application.put_env(:portal, Leases, long_poll_ms: 50)
    previous_l2 = Application.get_env(:portal, L2)
    RateLimit.reset()

    on_exit(fn ->
      Application.delete_env(:portal, Leases)

      if previous_l2,
        do: Application.put_env(:portal, L2, previous_l2),
        else: Application.delete_env(:portal, L2)
    end)

    {:ok, s3} = FakeS3.start()

    Application.put_env(:portal, L2,
      endpoint: s3.endpoint,
      bucket: s3.bucket,
      region: s3.region,
      access_key: s3.access_key,
      secret_key: s3.secret_key,
      read_only: true
    )

    %{builder: builder, cert_der: der} = enrolled_builder!("bc1")
    %{builder: other, cert_der: other_der} = enrolled_builder!("bc2")

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
        image_digest: @digest,
        args: %{},
        scan_request_id: request.id,
        priority: 5
      })

    {:ok, lease} = Leases.claim(builder)

    tmp = Path.join(System.tmp_dir!(), "bc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)
    entry = Path.join(tmp, "entry")
    File.mkdir_p!(Path.join(entry, "ebin"))
    File.write!(Path.join(entry, "ebin/x.beam"), "beam")
    {:ok, %{sha256: sha}} = Tarball.pack(entry, Path.join(tmp, "e.tar.gz"), :any)
    body = File.read!(Path.join(tmp, "e.tar.gz"))
    key = String.duplicate("a", 64)
    FakeS3.put_object(s3, "#{@slug}/#{key}.tar.gz", body, %{"x-amz-meta-sha256" => sha})

    %{
      der: der,
      other: other,
      other_der: other_der,
      lease: lease,
      builder: builder,
      s3: s3,
      key: key,
      sha: sha,
      body: body
    }
  end

  defp offer(conn, der, lease_id, body \\ %{}) do
    conn
    |> with_cert(der)
    |> post("/builder/v1/jobs/#{lease_id}/build-cache", body)
  end

  test "the holder of a leased lease gets presigned GETs for its image's slug", ctx do
    log =
      capture_log([level: :info], fn ->
        conn = offer(ctx.conn, ctx.der, ctx.lease.id)
        send(self(), {:body, json_response(conn, 200)})
      end)

    assert_received {:body, body}
    assert body["slug"] == @slug
    assert {:ok, _, _} = DateTime.from_iso8601(body["expires_at"])
    assert [%{"key" => key, "sha256" => sha, "size" => size, "url" => url}] = body["entries"]
    assert key == ctx.key and sha == ctx.sha and size == byte_size(ctx.body)

    assert {:ok, %Req.Response{status: 200, body: got}} =
             Req.get(url, retry: false, decode_body: false)

    assert got == ctx.body

    # Neither the secret nor the signed query reaches the log.
    refute log =~ ctx.s3.secret_key
    refute log =~ "X-Amz-Signature"
    refute inspect(body) =~ ctx.s3.secret_key
  end

  test "what the builder already has is left out", ctx do
    assert %{"entries" => []} =
             offer(ctx.conn, ctx.der, ctx.lease.id, %{"have" => [ctx.key]}) |> json_response(200)
  end

  test "another builder's lease, an unknown one and a malformed id are not held", ctx do
    assert %{"error" => "lease_not_held"} =
             offer(ctx.conn, ctx.other_der, ctx.lease.id) |> json_response(409)

    assert %{"error" => "lease_not_held"} =
             offer(ctx.conn, ctx.der, Ecto.UUID.generate()) |> json_response(409)

    assert %{"error" => "lease_not_held"} =
             offer(ctx.conn, ctx.der, "not-a-uuid") |> json_response(409)
  end

  test "a lease past its build (uploading) gets no offer", ctx do
    {:ok, _} = Leases.heartbeat(ctx.lease.id, ctx.builder.id, "uploading", nil)
    assert Ash.get!(Lease, ctx.lease.id, domain: Portal.Builders).state == :uploading

    assert %{"error" => "lease_not_held"} =
             offer(ctx.conn, ctx.der, ctx.lease.id) |> json_response(409)
  end

  test "no certificate, no offer", ctx do
    conn = post(ctx.conn, "/builder/v1/jobs/#{ctx.lease.id}/build-cache", %{})
    assert conn.status in [401, 403]
  end

  test "with L2 off the offer is empty", ctx do
    Application.delete_env(:portal, L2)

    assert %{"entries" => [], "slug" => @slug} =
             offer(ctx.conn, ctx.der, ctx.lease.id) |> json_response(200)
  end

  test "a malformed or oversized have list is refused", ctx do
    assert %{"error" => "bad_have"} =
             offer(ctx.conn, ctx.der, ctx.lease.id, %{"have" => "x"}) |> json_response(422)

    assert %{"error" => "bad_have"} =
             offer(ctx.conn, ctx.der, ctx.lease.id, %{"have" => [1]}) |> json_response(422)

    too_many = List.duplicate(ctx.key, 20_001)

    assert %{"error" => "bad_have"} =
             offer(ctx.conn, ctx.der, ctx.lease.id, %{"have" => too_many}) |> json_response(422)
  end

  test "offers are rate limited per builder", ctx do
    for _ <- 1..30, do: assert(offer(ctx.conn, ctx.der, ctx.lease.id).status == 200)

    assert %{"error" => "rate_limited"} =
             offer(ctx.conn, ctx.der, ctx.lease.id) |> json_response(429)
  end
end
