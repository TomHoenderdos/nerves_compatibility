defmodule Portal.Builders.CATest do
  use ExUnit.Case, async: false

  alias Portal.Builders.CA

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir, key_path: key_path}
  end

  defp csr_pem do
    key = X509.PrivateKey.new_ec(:secp256r1)
    X509.CSR.new(key, "/CN=ignored") |> X509.CSR.to_pem()
  end

  test "init writes a P-256 CA with key mode 600 and refuses to overwrite", %{key_path: key_path} do
    assert {:ok, %{key_path: ^key_path, cert_path: cert_path}} = CA.init(key_path)
    assert File.stat!(key_path).mode |> Bitwise.band(0o777) == 0o600
    assert {:ok, %{key: _, cert: cert}} = CA.load()
    assert String.length(CA.fingerprint(cert)) == 64
    assert CA.prefix(cert) == String.slice(CA.fingerprint(cert), 0, 16)
    assert {:ok, "-----BEGIN CERTIFICATE-----" <> _} = CA.cert_pem()
    assert File.exists?(cert_path)
    assert {:error, :exists} = CA.init(key_path)
  end

  test "unconfigured and missing CAs are distinguishable", %{key_path: key_path} do
    assert {:error, :missing} = CA.load()
    Application.put_env(:portal, CA, [])
    assert {:error, :not_configured} = CA.load()
    refute File.exists?(key_path)
  end

  test "issues a one-year client certificate naming the builder, ignoring the CSR subject", %{
    key_path: key_path
  } do
    {:ok, _} = CA.init(key_path)

    assert {:ok, %{pem: pem, fingerprint: fp, expires_at: expires}} =
             CA.issue_client(csr_pem(), "box-a", "b1d2")

    cert = X509.Certificate.from_pem!(pem)
    assert X509.Certificate.subject(cert, "CN") == ["box-a"]
    assert X509.Certificate.subject(cert, "serialNumber") == ["b1d2"]
    assert fp == CA.fingerprint(cert)
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 364..366
    assert CA.expires_at(cert) == expires
    assert X509.Certificate.extension(cert, :subject_alt_name) == nil

    {:ok, %{cert: ca}} = CA.load()
    assert :public_key.pkix_is_issuer(X509.Certificate.to_der(cert), X509.Certificate.to_der(ca))

    assert {:ok, _} =
             :public_key.pkix_path_validation(
               X509.Certificate.to_der(ca),
               [X509.Certificate.to_der(cert)],
               []
             )
  end

  # The agent generates a P-256 key; signing whatever key a CSR carries
  # would let a machine enrol with a short RSA key or an odd curve.
  test "a CSR for anything but a P-256 key is refused", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)
    csr = X509.PrivateKey.new_ec(:secp384r1) |> X509.CSR.new("/CN=x") |> X509.CSR.to_pem()
    assert {:error, :invalid_csr} = CA.issue_client(csr, "b1", Ecto.UUID.generate())
    csr = X509.PrivateKey.new_rsa(1024) |> X509.CSR.new("/CN=x") |> X509.CSR.to_pem()
    assert {:error, :invalid_csr} = CA.issue_client(csr, "b1", Ecto.UUID.generate())
  end

  test "a CSR with a tampered signature is refused", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)
    der = csr_pem() |> X509.CSR.from_pem!() |> X509.CSR.to_der()
    size = byte_size(der) - 1
    <<head::binary-size(^size), last>> = der
    tampered = <<head::binary, Bitwise.bxor(last, 0xFF)>>
    pem = :public_key.pem_encode([{:CertificationRequest, tampered, :not_encrypted}])

    assert {:ok, csr} = X509.CSR.from_pem(pem)
    refute X509.CSR.valid?(csr)
    assert {:error, :invalid_csr} = CA.issue_client(pem, "x", "y")
  end

  test "builder names that would inject subject components are refused", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)

    for bad <- ["a/CN=b", "a=b", "", "-x", String.duplicate("a", 65), "a b"] do
      refute CA.valid_name?(bad)
      assert {:error, :invalid_name} = CA.issue_client(csr_pem(), bad, "id")
    end

    assert CA.valid_name?("box-a.1_x")
  end

  test "ensure_server_cert refuses hosts that are not plain names", %{key_path: key_path} do
    {:ok, _} = CA.init(key_path)
    assert {:error, :invalid_host} = CA.ensure_server_cert("")
    assert {:error, :invalid_host} = CA.ensure_server_cert("a/CN=b")
  end

  test "ensure_server_cert reissues after the CA is rotated", %{key_path: key_path, dir: dir} do
    {:ok, _} = CA.init(key_path)
    {:ok, %{certfile: certfile}} = CA.ensure_server_cert("portal.example")
    old = File.read!(certfile)

    File.rm!(key_path)
    File.rm!(Path.join(dir, "ca.pem"))
    {:ok, _} = CA.init(key_path)

    assert {:ok, _} = CA.ensure_server_cert("portal.example")
    new = File.read!(certfile)
    refute new == old
    {:ok, %{cert: ca}} = CA.load()

    assert :public_key.pkix_verify(
             new |> X509.Certificate.from_pem!() |> X509.Certificate.to_der(),
             X509.Certificate.public_key(ca)
           )
  end

  # The CA dir may be unwritable by the service (wrong owner, disk full);
  # that must reach the listener as an error, not take the public site down.
  test "ensure_server_cert in an unwritable CA dir is an error, not a crash", %{
    key_path: key_path,
    dir: dir
  } do
    {:ok, _} = CA.init(key_path)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert {:error, {:server_cert, _}} = CA.ensure_server_cert("portal.example")
    File.chmod!(dir, 0o700)
    assert {:ok, _} = CA.ensure_server_cert("portal.example")
  end

  test "ensure_server_cert reissues when the key file is missing", %{key_path: key_path, dir: dir} do
    {:ok, _} = CA.init(key_path)
    {:ok, %{keyfile: keyfile}} = CA.ensure_server_cert("portal.example")
    File.rm!(keyfile)
    assert {:ok, _} = CA.ensure_server_cert("portal.example")
    assert File.exists?(Path.join(dir, "server-key.pem"))
  end

  test "init leaves no temp files behind", %{key_path: key_path, dir: dir} do
    {:ok, _} = CA.init(key_path)
    assert {:error, :exists} = CA.init(key_path)
    assert dir |> File.ls!() |> Enum.sort() == ["ca-key.pem", "ca.pem"]
  end

  test "ensure_server_cert issues a SAN certificate once and reuses it", %{
    key_path: key_path,
    dir: dir
  } do
    {:ok, _} = CA.init(key_path)

    assert {:ok, %{certfile: certfile, keyfile: keyfile}} =
             CA.ensure_server_cert("portal.example")

    assert certfile == Path.join(dir, "server.pem")
    assert File.stat!(keyfile).mode |> Bitwise.band(0o777) == 0o600
    cert = certfile |> File.read!() |> X509.Certificate.from_pem!()
    assert X509.Certificate.subject(cert, "CN") == ["portal.example"]

    {:Extension, _, _, [dNSName: ~c"portal.example"]} =
      X509.Certificate.extension(cert, :subject_alt_name)

    # serverAuth only: the TLS layer refuses it as a client certificate.
    {:Extension, _, _, usages} = X509.Certificate.extension(cert, :ext_key_usage)
    assert usages == [{1, 3, 6, 1, 5, 5, 7, 3, 1}]

    first = File.read!(certfile)
    assert {:ok, _} = CA.ensure_server_cert("portal.example")
    assert File.read!(certfile) == first
  end
end
