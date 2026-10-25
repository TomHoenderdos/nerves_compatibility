defmodule NccAgent.Test.CA do
  @moduledoc "A throwaway CA, server certificate and client issuer for agent tests."

  def new(dir) do
    File.mkdir_p!(dir)
    key = X509.PrivateKey.new_ec(:secp256r1)
    cert = X509.Certificate.self_signed(key, "/CN=test CA", template: :root_ca)
    File.write!(Path.join(dir, "ca.pem"), X509.Certificate.to_pem(cert))
    server_key = X509.PrivateKey.new_ec(:secp256r1)

    server =
      X509.Certificate.new(
        X509.PublicKey.derive(server_key),
        "/CN=localhost",
        cert,
        key,
        template: :server,
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])]
      )

    File.write!(Path.join(dir, "server.pem"), X509.Certificate.to_pem(server))
    File.write!(Path.join(dir, "server-key.pem"), X509.PrivateKey.to_pem(server_key))

    %{
      dir: dir,
      key: key,
      cert: cert,
      prefix:
        cert
        |> X509.Certificate.to_der()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)
    }
  end

  def issue(%{key: key, cert: cert}, csr_pem, name, days \\ 365) do
    csr = X509.CSR.from_pem!(csr_pem)

    X509.Certificate.new(X509.CSR.public_key(csr), "/CN=#{name}", cert, key,
      template: :server,
      validity: days
    )
    |> X509.Certificate.to_pem()
  end
end
