defmodule Portal.Builders.CA do
  @moduledoc """
  The portal's own certificate authority for remote builders: an ECDSA P-256
  root at `NCC_BUILDER_CA_KEY` (owner `ncc`, mode 600), its certificate next
  to it as `ca.pem`, and the mTLS listener's server certificate it signs
  (`server.pem`/`server-key.pem`, renewed when missing or within 30 days of
  expiry). Client certificates are issued for one year from a CSR whose
  subject is ignored: `CN=<builder name>`, `serialNumber=<builder id>`.

  Losing the key means a new CA and re-enrolling every builder: the
  enrolment token carries the CA certificate's sha256 prefix, so a rotated
  CA is a new token, never a new agent image.
  """

  @client_days 365
  @server_days 365
  @server_renew_within_days 30

  @spec key_path() :: Path.t() | nil
  def key_path, do: :portal |> Application.get_env(__MODULE__, []) |> Keyword.get(:key_path)

  @spec dir() :: Path.t() | nil
  def dir, do: if(path = key_path(), do: Path.dirname(path))

  @spec cert_path() :: Path.t() | nil
  def cert_path, do: if(d = dir(), do: Path.join(d, "ca.pem"))

  @spec server_cert_path() :: Path.t() | nil
  def server_cert_path, do: if(d = dir(), do: Path.join(d, "server.pem"))

  @spec server_key_path() :: Path.t() | nil
  def server_key_path, do: if(d = dir(), do: Path.join(d, "server-key.pem"))

  @doc "Create the CA at `key_path` (key mode 600, `ca.pem` beside it). Refuses an existing key."
  @spec init(Path.t()) :: {:ok, %{key_path: Path.t(), cert_path: Path.t()}} | {:error, term()}
  # The path is operator input to a mix task or `bin/portal eval`, never a request.
  # sobelow_skip ["Traversal.FileModule"]
  def init(key_path) do
    cert_path = Path.join(Path.dirname(key_path), "ca.pem")

    if File.exists?(key_path) do
      {:error, :exists}
    else
      key = X509.PrivateKey.new_ec(:secp256r1)
      cert = X509.Certificate.self_signed(key, "/CN=ncc builder CA", template: :root_ca)
      File.mkdir_p!(Path.dirname(key_path))
      write_private(key_path, X509.PrivateKey.to_pem(key))
      File.write!(cert_path, X509.Certificate.to_pem(cert))
      {:ok, %{key_path: key_path, cert_path: cert_path}}
    end
  end

  @spec load() ::
          {:ok, %{key: term(), cert: term()}} | {:error, :not_configured | :missing | :unreadable}
  # Operator-configured paths.
  # sobelow_skip ["Traversal.FileModule"]
  def load do
    case key_path() do
      nil ->
        {:error, :not_configured}

      key_path ->
        with {:ok, key_pem} <- File.read(key_path),
             {:ok, cert_pem} <- File.read(cert_path()),
             {:ok, key} <- X509.PrivateKey.from_pem(key_pem),
             {:ok, cert} <- X509.Certificate.from_pem(cert_pem) do
          {:ok, %{key: key, cert: cert}}
        else
          {:error, :enoent} -> {:error, :missing}
          _ -> {:error, :unreadable}
        end
    end
  end

  @spec cert_pem() :: {:ok, String.t()} | {:error, term()}
  def cert_pem do
    with {:ok, %{cert: cert}} <- load(), do: {:ok, X509.Certificate.to_pem(cert)}
  end

  @doc "Lowercase hex sha256 of the certificate's DER."
  @spec fingerprint(term()) :: String.t()
  def fingerprint(cert), do: cert |> X509.Certificate.to_der() |> fingerprint_der()

  @spec fingerprint_der(binary()) :: String.t()
  def fingerprint_der(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  @spec prefix(term()) :: String.t()
  def prefix(cert), do: cert |> fingerprint() |> String.slice(0, 16)

  @spec issue_client(String.t(), String.t(), String.t()) ::
          {:ok, %{pem: String.t(), fingerprint: String.t(), expires_at: DateTime.t()}}
          | {:error, :invalid_csr}
  def issue_client(csr_pem, name, builder_id) do
    with {:ok, %{key: ca_key, cert: ca_cert}} <- load(),
         {:ok, csr} <- X509.CSR.from_pem(csr_pem),
         true <- X509.CSR.valid?(csr) do
      cert =
        X509.Certificate.new(
          X509.CSR.public_key(csr),
          "/CN=#{name}/serialNumber=#{builder_id}",
          ca_cert,
          ca_key,
          template: :server,
          validity: @client_days,
          extensions: [ext_key_usage: X509.Certificate.Extension.ext_key_usage([:clientAuth])]
        )

      {:ok,
       %{
         pem: X509.Certificate.to_pem(cert),
         fingerprint: fingerprint(cert),
         expires_at: expires_at(cert)
       }}
    else
      _ -> {:error, :invalid_csr}
    end
  end

  @spec expires_at(term()) :: DateTime.t()
  def expires_at(cert) do
    {:Validity, _not_before, not_after} = X509.Certificate.validity(cert)
    X509.DateTime.to_datetime(not_after)
  end

  @spec not_after_from_pem(String.t()) :: {:ok, DateTime.t()} | :error
  def not_after_from_pem(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} -> {:ok, expires_at(cert)}
      _ -> :error
    end
  end

  @doc "The listener's certificate for `host`, issued when missing or expiring within 30 days."
  @spec ensure_server_cert(String.t()) ::
          {:ok, %{certfile: Path.t(), keyfile: Path.t()}} | {:error, term()}
  # Operator-configured paths.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_server_cert(host) do
    with {:ok, %{key: ca_key, cert: ca_cert}} <- load() do
      certfile = server_cert_path()
      keyfile = server_key_path()

      if server_cert_current?(certfile, host) do
        {:ok, %{certfile: certfile, keyfile: keyfile}}
      else
        key = X509.PrivateKey.new_ec(:secp256r1)

        cert =
          X509.Certificate.new(X509.PublicKey.derive(key), "/CN=#{host}", ca_cert, ca_key,
            template: :server,
            validity: @server_days,
            extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([host])]
          )

        write_private(keyfile, X509.PrivateKey.to_pem(key))
        File.write!(certfile, X509.Certificate.to_pem(cert))
        {:ok, %{certfile: certfile, keyfile: keyfile}}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp server_cert_current?(certfile, host) do
    with {:ok, pem} <- File.read(certfile),
         {:ok, cert} <- X509.Certificate.from_pem(pem),
         [^host] <- X509.Certificate.subject(cert, "CN") do
      DateTime.diff(expires_at(cert), DateTime.utc_now(), :day) > @server_renew_within_days
    else
      _ -> false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_private(path, pem) do
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
