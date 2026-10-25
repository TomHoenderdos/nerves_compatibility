defmodule PortalWeb.BuilderListenerTLSTest do
  # Starts Bandit with `Listener.https_options/1` for real: Bandit validates
  # the option shape, and a TLS handshake proves the CA, the server
  # certificate and the optional client certificate are wired as intended.
  use ExUnit.Case, async: false

  alias Portal.Builders.{CA, Listener}

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    {:ok, _} = CA.init(key_path)

    opts =
      "localhost"
      |> Listener.https_options()
      |> Keyword.merge(port: 0, ip: {127, 0, 0, 1})

    server =
      start_supervised!(
        {Bandit, [plug: PortalWeb.BuilderRouter, scheme: :https, startup_log: false] ++ opts}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{dir: dir, port: port}
  end

  defp connect(port, extra) do
    :ssl.connect(
      ~c"localhost",
      port,
      [
        verify: :verify_peer,
        cacertfile: String.to_charlist(CA.cert_path()),
        server_name_indication: ~c"localhost",
        active: false,
        mode: :binary
      ] ++ extra,
      5_000
    )
  end

  defp client_cert(dir, name, issuer) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    pem =
      case issuer do
        :ca ->
          csr = X509.CSR.new(key, "/CN=#{name}") |> X509.CSR.to_pem()
          {:ok, %{pem: pem}} = CA.issue_client(csr, name, Ecto.UUID.generate())
          pem

        :self ->
          key |> X509.Certificate.self_signed("/CN=#{name}") |> X509.Certificate.to_pem()
      end

    certfile = Path.join(dir, "#{name}.pem")
    keyfile = Path.join(dir, "#{name}-key.pem")
    File.write!(certfile, pem)
    File.write!(keyfile, X509.PrivateKey.to_pem(key))
    [certfile: String.to_charlist(certfile), keyfile: String.to_charlist(keyfile)]
  end

  defp get_ca_pem(socket) do
    :ok = :ssl.send(socket, "GET /builder/v1/ca.pem HTTP/1.1\r\nhost: localhost\r\n\r\n")
    :ssl.recv(socket, 0, 5_000)
  end

  test "a client without a certificate completes the handshake (enrolment is open)", %{port: port} do
    assert {:ok, socket} = connect(port, [])
    assert {:ok, "HTTP/1.1 " <> _} = get_ca_pem(socket)
    :ssl.close(socket)
  end

  test "a client with a CA-issued certificate completes the handshake", %{dir: dir, port: port} do
    assert {:ok, socket} = connect(port, client_cert(dir, "box-tls", :ca))
    assert {:ok, "HTTP/1.1 " <> _} = get_ca_pem(socket)
    :ssl.close(socket)
  end

  test "a client certificate from another issuer is refused", %{dir: dir, port: port} do
    # Under TLS 1.3 the client may finish its side before the server rejects
    # the certificate, so the refusal shows on connect or on the first read.
    case connect(port, client_cert(dir, "stray", :self)) do
      {:error, _} -> :ok
      {:ok, socket} -> assert {:error, _} = get_ca_pem(socket)
    end
  end
end
