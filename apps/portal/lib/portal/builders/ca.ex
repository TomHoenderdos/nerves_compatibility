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

  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @doc """
  Whether `name` is safe as a certificate subject component (a builder name
  or a host): it is interpolated into an RDN string, so `/` and `=` are out.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  @doc "Create the CA at `key_path` (key mode 600, `ca.pem` beside it). Refuses an existing key."
  @spec init(Path.t()) :: {:ok, %{key_path: Path.t(), cert_path: Path.t()}} | {:error, :exists}
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
      key_tmp = stage_private(key_path, X509.PrivateKey.to_pem(key))
      cert_tmp = stage(cert_path, X509.Certificate.to_pem(cert), 0o644)

      publish_ca(key_tmp, cert_tmp, key_path, cert_path)
    end
  end

  # A hard link fails if the key appeared meanwhile, so two inits cannot
  # both win; the key goes live first and the certificate follows at once.
  # sobelow_skip ["Traversal.FileModule"]
  defp publish_ca(key_tmp, cert_tmp, key_path, cert_path) do
    case :file.make_link(String.to_charlist(key_tmp), String.to_charlist(key_path)) do
      :ok ->
        File.rm!(key_tmp)
        publish_ca_cert(cert_tmp, key_path, cert_path)

      {:error, _} ->
        File.rm(key_tmp)
        File.rm(cert_tmp)
        {:error, :exists}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp publish_ca_cert(cert_tmp, key_path, cert_path) do
    case File.rename(cert_tmp, cert_path) do
      :ok ->
        {:ok, %{key_path: key_path, cert_path: cert_path}}

      {:error, reason} ->
        File.rm(key_path)
        raise File.Error, reason: reason, action: "rename", path: cert_path
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

  @doc """
  The CA certificate as PEM, for the unauthenticated `ca.pem` route. Reads
  only `ca.pem`: the private key is not touched to answer a request anyone
  can send.
  """
  @spec cert_pem() :: {:ok, String.t()} | {:error, :not_configured | :missing | :unreadable}
  # Operator-configured path.
  # sobelow_skip ["Traversal.FileModule"]
  def cert_pem do
    if key_path() do
      with {:ok, pem} <- File.read(cert_path()),
           {:ok, cert} <- X509.Certificate.from_pem(pem) do
        {:ok, X509.Certificate.to_pem(cert)}
      else
        {:error, :enoent} -> {:error, :missing}
        _ -> {:error, :unreadable}
      end
    else
      {:error, :not_configured}
    end
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
          | {:error, :invalid_csr | :invalid_name}
  def issue_client(csr_pem, name, builder_id) do
    if valid_name?(name) do
      do_issue_client(csr_pem, name, builder_id)
    else
      {:error, :invalid_name}
    end
  end

  # Only the key the agent generates (`NccAgent.Identity`): a P-256 EC key.
  # Signing whatever key a CSR carries would let a machine enrol with a
  # short RSA key or an odd curve, and `X509.Certificate.new/5` raises on
  # types it cannot encode.
  @p256_curve {1, 2, 840, 10_045, 3, 1, 7}

  defp do_issue_client(csr_pem, name, builder_id) do
    with {:ok, %{key: ca_key, cert: ca_cert}} <- load(),
         {:ok, csr} <- X509.CSR.from_pem(csr_pem),
         true <- X509.CSR.valid?(csr),
         true <- p256?(X509.CSR.public_key(csr)) do
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

  defp p256?({{:ECPoint, _point}, {:namedCurve, @p256_curve}}), do: true
  defp p256?(_key), do: false

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

  @doc "The listener's certificate for `host`, issued when missing, stale, or expiring within 30 days."
  @spec ensure_server_cert(String.t()) ::
          {:ok, %{certfile: Path.t(), keyfile: Path.t()}} | {:error, term()}
  # Operator-configured paths.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_server_cert(host) do
    with :ok <- check_host(host),
         {:ok, %{key: ca_key, cert: ca_cert}} <- load() do
      certfile = server_cert_path()
      keyfile = server_key_path()
      paths = %{certfile: certfile, keyfile: keyfile}

      with :ok <- current_or_issued(host, ca_key, ca_cert, certfile, keyfile), do: {:ok, paths}
    end
  end

  defp current_or_issued(host, ca_key, ca_cert, certfile, keyfile) do
    if server_cert_current?(certfile, keyfile, host, ca_cert),
      do: :ok,
      else: issue_server_cert(host, ca_key, ca_cert, certfile, keyfile)
  end

  defp check_host(host), do: if(valid_name?(host), do: :ok, else: {:error, :invalid_host})

  # A CA dir the service cannot write (wrong owner, disk full) is an error
  # the listener reports and runs without, never a crash of the application
  # that also serves the public site.
  # sobelow_skip ["Traversal.FileModule"]
  defp issue_server_cert(host, ca_key, ca_cert, certfile, keyfile) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    # serverAuth only: the TLS layer then refuses this certificate as a
    # client certificate, whether or not a builder row exists for it.
    cert =
      X509.Certificate.new(X509.PublicKey.derive(key), "/CN=#{host}", ca_cert, ca_key,
        template: :server,
        validity: @server_days,
        extensions: [
          subject_alt_name: X509.Certificate.Extension.subject_alt_name([host]),
          ext_key_usage: X509.Certificate.Extension.ext_key_usage([:serverAuth])
        ]
      )

    # Stage both before either goes live. A crash between the renames
    # leaves a key that does not match the certificate, which
    # server_cert_current?/4 treats as stale.
    key_tmp = stage_private(keyfile, X509.PrivateKey.to_pem(key))
    cert_tmp = stage(certfile, X509.Certificate.to_pem(cert), 0o644)
    File.rename!(key_tmp, keyfile)
    File.rename!(cert_tmp, certfile)
    :ok
  rescue
    e in [File.Error, MatchError] ->
      {:error, {:server_cert, Exception.message(e)}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp server_cert_current?(certfile, keyfile, host, ca_cert) do
    with {:ok, pem} <- File.read(certfile),
         {:ok, cert} <- X509.Certificate.from_pem(pem),
         {:ok, key_pem} <- File.read(keyfile),
         {:ok, key} <- X509.PrivateKey.from_pem(key_pem),
         [^host] <- X509.Certificate.subject(cert, "CN"),
         true <- X509.Certificate.public_key(cert) == X509.PublicKey.derive(key),
         true <- signed_by?(cert, ca_cert) do
      DateTime.diff(expires_at(cert), DateTime.utc_now(), :day) > @server_renew_within_days
    else
      _ -> false
    end
  end

  # Both CAs are named "ncc builder CA", so name matching (pkix_is_issuer)
  # cannot tell a rotated CA from the current one; the signature can.
  defp signed_by?(cert, ca_cert) do
    :public_key.pkix_verify(X509.Certificate.to_der(cert), X509.Certificate.public_key(ca_cert))
  end

  defp stage_private(path, pem), do: stage(path, pem, 0o600)

  # Write `pem` to a fresh sibling of `path` created exclusively, restrict it
  # before any content lands, and return the temp path for the caller to
  # rename into place.
  # sobelow_skip ["Traversal.FileModule"]
  defp stage(path, pem, mode) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
    {:ok, io} = File.open(tmp, [:write, :exclusive, :binary])
    File.chmod!(tmp, mode)
    # A short write (ENOSPC) must not leave a truncated key to be renamed
    # into place and handed to the listener; the MatchError is the caller's.
    :ok = IO.binwrite(io, pem)
    :ok = File.close(io)
    tmp
  end
end
