defmodule PortalWeb.Plugs.BuilderCertTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders

  @status %{"agent_version" => "1", "egress" => "ok"}

  test "no certificate is 401", %{conn: conn} do
    conn = conn |> without_cert() |> post("/builder/v1/status", @status)
    assert json_response(conn, 401) == %{"error" => "client_certificate_required"}
  end

  test "the body is not parsed before the certificate is checked", %{conn: conn} do
    conn =
      conn
      |> without_cert()
      |> put_req_header("content-type", "application/json")
      |> post("/builder/v1/status", Jason.encode!(@status))

    assert json_response(conn, 401) == %{"error" => "client_certificate_required"}
    assert %Plug.Conn.Unfetched{} = conn.body_params
  end

  test "the agent version in a status body is recorded", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-v")

    conn =
      conn
      |> with_cert(der)
      |> post("/builder/v1/status", %{"agent_version" => "8.y", "egress" => "ok"})

    assert json_response(conn, 200) == %{"ok" => true}
    {:ok, seen} = Builders.get_builder(builder.id)
    assert seen.last_version == "8.y"
    assert seen.egress_status == "ok"
  end

  test "an unknown certificate is 403", %{conn: conn} do
    stray =
      X509.PrivateKey.new_ec(:secp256r1)
      |> X509.Certificate.self_signed("/CN=stray")
      |> X509.Certificate.to_der()

    conn = conn |> with_cert(stray) |> post("/builder/v1/status", @status)
    assert json_response(conn, 403) == %{"error" => "unknown_builder"}
  end

  test "a known certificate is assigned and refreshes last_seen_at", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-p")
    assert builder.last_seen_at == nil

    conn =
      conn
      |> with_cert(der)
      |> put_req_header("x-ncc-agent-version", "7.x")
      |> post("/builder/v1/status", %{"agent_version" => "7.x", "egress" => "missing"})

    assert json_response(conn, 200) == %{"ok" => true}
    {:ok, seen} = Builders.get_builder(builder.id)
    assert %DateTime{} = seen.last_seen_at
    assert seen.last_version == "7.x"
    assert seen.egress_status == "missing"
  end

  test "a revoked builder is 403 on its next request", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-q")
    {:ok, _} = Builders.revoke(builder)
    conn = conn |> with_cert(der) |> post("/builder/v1/status", @status)
    assert json_response(conn, 403) == %{"error" => "builder_revoked"}
  end

  test "a superseded certificate is accepted for 24 h and refused after", %{conn: conn} do
    %{builder: builder, cert_der: old_der} = enrolled_builder!("box-s")

    near =
      builder
      |> Ash.Changeset.for_update(:rotate_cert, %{
        cert_expires_at: DateTime.add(DateTime.utc_now(), 5, :day),
        fingerprint: builder.fingerprint,
        cert_pem: builder.cert_pem
      })
      |> Ash.update!(domain: Builders)

    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, _} = Builders.renew(near, csr)

    assert %{"ok" => true} =
             conn
             |> with_cert(old_der)
             |> post("/builder/v1/status", @status)
             |> json_response(200)

    old_fp = Portal.Builders.CA.fingerprint_der(old_der)

    cert =
      Portal.Builders.BuilderCertificate
      |> Ash.Query.filter(fingerprint == ^old_fp)
      |> Ash.read_one!(domain: Builders)

    cert
    |> Ash.Changeset.for_update(:update_superseded_at, %{
      superseded_at: DateTime.add(DateTime.utc_now(), -25, :hour)
    })
    |> Ash.update!(domain: Builders)

    assert conn |> with_cert(old_der) |> post("/builder/v1/status", @status) |> json_response(403) ==
             %{"error" => "unknown_builder"}
  end
end
