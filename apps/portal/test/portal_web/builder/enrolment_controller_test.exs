defmodule PortalWeb.Builder.EnrolmentControllerTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders

  defp csr do
    key = X509.PrivateKey.new_ec(:secp256r1)
    {key, X509.CSR.new(key, "/CN=whatever") |> X509.CSR.to_pem()}
  end

  test "ca.pem is served without a certificate", %{conn: conn} do
    conn = conn |> without_cert() |> get("/builder/v1/ca.pem")
    assert response(conn, 200) =~ "BEGIN CERTIFICATE"
    assert response_content_type(conn, :"x-pem-file") =~ "application/x-pem-file"
  end

  test "enrolment exchanges a token and CSR for a certificate", %{conn: conn} do
    {:ok, %{token: token}} = Builders.create_token("box-1", "admin")
    {_key, csr_pem} = csr()

    conn =
      conn
      |> without_cert()
      |> post("/builder/v1/enroll", %{
        "token" => token,
        "csr_pem" => csr_pem,
        "agent_version" => "1.a",
        "slots" => 2
      })

    assert %{"certificate_pem" => pem, "builder_id" => id, "name" => "box-1", "expires_at" => _} =
             json_response(conn, 201)

    assert {:ok, builder} = Builders.get_builder(id)
    assert builder.fingerprint == Portal.Builders.CA.fingerprint(X509.Certificate.from_pem!(pem))
    assert builder.slots == 2
    assert builder.last_version == "1.a"

    assert build_conn()
           |> without_cert()
           |> post("/builder/v1/enroll", %{"token" => token, "csr_pem" => csr_pem})
           |> json_response(401) == %{"error" => "token_used"}

    assert build_conn()
           |> without_cert()
           |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => csr_pem})
           |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "a bad CSR is 422 and a missing body is 400", %{conn: conn} do
    {:ok, %{token: token}} = Builders.create_token("box-2", "admin")

    assert conn
           |> without_cert()
           |> post("/builder/v1/enroll", %{"token" => token, "csr_pem" => "garbage"})
           |> json_response(422) == %{"error" => "invalid_csr"}

    assert %{"error" => "bad_request"} =
             conn |> without_cert() |> post("/builder/v1/enroll", %{}) |> json_response(400)
  end

  test "enrolment is rate limited per address", %{conn: conn} do
    for _ <- 1..10 do
      conn
      |> without_cert()
      |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => "x"})
    end

    assert conn
           |> without_cert()
           |> post("/builder/v1/enroll", %{"token" => "a.b.c", "csr_pem" => "x"})
           |> json_response(429) == %{"error" => "rate_limited"}
  end

  test "renewal needs the client certificate and the window", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("box-3")
    {_k, csr_pem} = csr()

    assert conn
           |> with_cert(der)
           |> post("/builder/v1/renew", %{"csr_pem" => csr_pem})
           |> json_response(425) == %{"error" => "too_early"}

    builder
    |> Ash.Changeset.for_update(:rotate_cert, %{
      cert_expires_at: DateTime.add(DateTime.utc_now(), 5, :day),
      fingerprint: builder.fingerprint,
      cert_pem: builder.cert_pem
    })
    |> Ash.update!(domain: Builders)

    assert %{"certificate_pem" => "-----BEGIN CERTIFICATE-----" <> _, "expires_at" => _} =
             conn
             |> with_cert(der)
             |> post("/builder/v1/renew", %{"csr_pem" => csr_pem})
             |> json_response(200)

    assert %{"error" => "client_certificate_required"} =
             conn
             |> without_cert()
             |> post("/builder/v1/renew", %{"csr_pem" => csr_pem})
             |> json_response(401)
  end
end
