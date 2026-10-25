defmodule NccAgent.Identity do
  @moduledoc """
  The agent's mTLS identity: the portal CA (`ca.pem`), the client
  certificate (`client.pem`) and its P-256 key (`client-key.pem`, 0600) in
  the data dir, plus the last CSR (`client.csr`).

  `ensure/0` enrols on first boot with `NCC_ENROLMENT_TOKEN` (fetching the
  CA and checking it against the token's prefix before trusting it), and
  renews a certificate that expires within 30 days. It returns the mTLS
  `Req` that `client/0` then hands out; a renewal rebuilds it.
  """
  use GenServer

  require Logger

  alias NccAgent.{Client, Config, Token, Version}

  @renew_within_days 30
  @call_timeout 180_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Enrols or renews as needed and returns the mTLS `Req`."
  @spec ensure() :: {:ok, Req.Request.t()} | {:error, term()}
  def ensure, do: GenServer.call(__MODULE__, :ensure, @call_timeout)

  @doc "The `Req` from the last successful `ensure/0`, or `nil`."
  @spec client() :: Req.Request.t() | nil
  def client, do: GenServer.call(__MODULE__, :client)

  @doc "When the current certificate expires, or `nil` before `ensure/0`."
  @spec cert_expires_at() :: DateTime.t() | nil
  def cert_expires_at, do: GenServer.call(__MODULE__, :cert_expires_at)

  @impl true
  def init(_opts), do: {:ok, %{req: nil, expires_at: nil}}

  @impl true
  def handle_call(:ensure, _from, state) do
    config = Config.get()

    with :ok <- enrol_if_needed(config),
         :ok <- check_pair(config),
         {:ok, expires_at} <- cert_expiry(config),
         {:ok, expires_at} <- renew_if_due(config, expires_at) do
      req = Client.new(config)
      {:reply, {:ok, req}, %{state | req: req, expires_at: expires_at}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:client, _from, state), do: {:reply, state.req, state}
  def handle_call(:cert_expires_at, _from, state), do: {:reply, state.expires_at, state}

  defp enrol_if_needed(config) do
    if File.exists?(Config.path(config, :cert)), do: :ok, else: enrol(config)
  end

  # Every path here is under the operator-configured data dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp enrol(config) do
    with {:ok, token} <- token(config.enrolment_token),
         {:ok, pem} <- Client.fetch_ca(config.portal_url),
         :ok <- Client.verify_ca(pem, token.ca_prefix),
         :ok <- File.mkdir_p(config.data_dir),
         :ok <- write_atomic(Config.path(config, :ca), pem, 0o644),
         {key, key_pem, csr_pem} = new_key_and_csr(),
         {:ok, enrolled} <-
           Client.enroll(
             config.portal_url,
             Config.path(config, :ca),
             String.trim(config.enrolment_token),
             csr_pem,
             Version.current(),
             config.slots
           ),
         :ok <- validate_issued(enrolled.cert_pem, key, Config.path(config, :ca)),
         :ok <- write_atomic(Config.path(config, :key), key_pem, 0o600),
         :ok <- write_atomic(Config.path(config, :csr), csr_pem, 0o644),
         :ok <- write_atomic(Config.path(config, :cert), enrolled.cert_pem, 0o644) do
      Logger.info("enrolled as builder #{enrolled.name} (#{enrolled.builder_id})")
      :ok
    end
  end

  defp token(nil), do: {:error, :no_enrolment_token}

  defp token(token) do
    case Token.parse(token) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_enrolment_token}
    end
  end

  defp renew_if_due(config, expires_at) do
    if DateTime.diff(expires_at, DateTime.utc_now(), :day) >= @renew_within_days do
      {:ok, expires_at}
    else
      renew(config, expires_at)
    end
  end

  # The new pair is written in full beside the current one, the current
  # pair is kept as `.prev`, and only then are key and certificate renamed
  # into place back to back. A crash between those two renames leaves a
  # mismatched pair that `check_pair/1` repairs from `.prev`.
  # sobelow_skip ["Traversal.FileModule"]
  defp renew(config, expires_at) do
    old = Client.new(config)
    {key, key_pem, csr_pem} = new_key_and_csr()
    key_path = Config.path(config, :key)
    cert_path = Config.path(config, :cert)

    with {:ok, renewed} <- Client.renew(old, csr_pem),
         :ok <- validate_issued(renewed.cert_pem, key, Config.path(config, :ca)),
         :ok <- write_tmp(key_path, key_pem, 0o600),
         :ok <- write_tmp(cert_path, renewed.cert_pem, 0o644),
         :ok <- copy_atomic(key_path, prev(key_path), 0o600),
         :ok <- copy_atomic(cert_path, prev(cert_path), 0o644),
         :ok <- rename(tmp(key_path), key_path),
         :ok <- rename(tmp(cert_path), cert_path),
         :ok <- write_atomic(Config.path(config, :csr), csr_pem, 0o644) do
      Client.drop_pool(old)

      Logger.info(
        "renewed the client certificate until #{DateTime.to_iso8601(renewed.expires_at)}"
      )

      cert_expiry(config)
    else
      {:error, reason} ->
        _ = File.rm(tmp(key_path))
        _ = File.rm(tmp(cert_path))
        renewal_failed(reason, expires_at)
    end
  end

  # A failed renewal is retried on the next `ensure/0`; until the
  # certificate actually expires the agent keeps working with it.
  defp renewal_failed(reason, expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      Logger.warning("certificate renewal failed (#{inspect(reason)}); it expires #{expires_at}")
      {:ok, expires_at}
    else
      {:error, {:renewal_failed, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cert_expiry(config) do
    with {:ok, pem} <- File.read(Config.path(config, :cert)),
         {:ok, cert} <- X509.Certificate.from_pem(pem) do
      {:Validity, _not_before, not_after} = X509.Certificate.validity(cert)
      {:ok, X509.DateTime.to_datetime(not_after)}
    else
      {:error, reason} -> {:error, {:bad_certificate, reason}}
    end
  end

  defp new_key_and_csr do
    key = X509.PrivateKey.new_ec(:secp256r1)
    csr = X509.CSR.new(key, "/CN=ncc-agent")
    {key, X509.PrivateKey.to_pem(key), X509.CSR.to_pem(csr)}
  end

  # An issued certificate is checked before any file moves: it parses,
  # carries the key we just generated, and chains to the portal CA.
  # sobelow_skip ["Traversal.FileModule"]
  defp validate_issued(cert_pem, key, ca_path) do
    with {:ok, cert} <- parse_cert(cert_pem),
         :ok <- same_key(cert, key),
         {:ok, ca_der} <- ca_der(ca_path),
         {:ok, _} <-
           :public_key.pkix_path_validation(ca_der, [X509.Certificate.to_der(cert)], []) do
      :ok
    else
      {:error, {:bad_certificate, _}} = error -> error
      {:error, reason} -> {:error, {:bad_certificate, reason}}
    end
  end

  defp parse_cert(pem) when is_binary(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} -> {:ok, cert}
      {:error, _} -> {:error, :unparsable}
    end
  end

  defp parse_cert(_), do: {:error, :unparsable}

  defp same_key(cert, key) do
    if X509.Certificate.public_key(cert) == X509.PublicKey.derive(key),
      do: :ok,
      else: {:error, :key_mismatch}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ca_der(ca_path) do
    with {:ok, pem} <- File.read(ca_path),
         {:ok, ca} <- X509.Certificate.from_pem(pem) do
      {:ok, X509.Certificate.to_der(ca)}
    else
      _ -> {:error, :no_ca}
    end
  end

  # The key and certificate on disk must belong together. A mismatch means
  # a renewal stopped between its two renames: the `.prev` pair, when it
  # matches, is put back (its certificate is still valid and the next
  # `ensure/0` renews again). Otherwise the identity is unusable.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_pair(config) do
    key_path = Config.path(config, :key)
    cert_path = Config.path(config, :cert)

    cond do
      pair_matches?(key_path, cert_path) ->
        :ok

      pair_matches?(prev(key_path), prev(cert_path)) ->
        Logger.warning("client key and certificate do not match; restoring the previous pair")

        with :ok <- copy_atomic(prev(key_path), key_path, 0o600),
             :ok <- copy_atomic(prev(cert_path), cert_path, 0o644) do
          :ok
        end

      true ->
        Logger.error(
          "client key #{key_path} does not match certificate #{cert_path} and there is " <>
            "no matching previous pair; remove both and re-enrol with a new token"
        )

        {:error, :identity_mismatch}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp pair_matches?(key_path, cert_path) do
    with {:ok, key_pem} <- File.read(key_path),
         {:ok, key} <- X509.PrivateKey.from_pem(key_pem),
         {:ok, cert_pem} <- File.read(cert_path),
         {:ok, cert} <- X509.Certificate.from_pem(cert_pem) do
      same_key(cert, key) == :ok
    else
      _ -> false
    end
  end

  defp tmp(path), do: path <> ".tmp"
  defp prev(path), do: path <> ".prev"

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_atomic(from, to, mode) do
    case File.read(from) do
      {:ok, contents} -> write_atomic(to, contents, mode)
      {:error, reason} -> {:error, {:read, from, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, to, reason}}
    end
  end

  # The temp file gets its mode before it gets any content, so a key is
  # never readable by others, and the rename replaces the old file whole.
  # `path` is one of the fixed `Config.path/2` names in the data dir.
  defp write_atomic(path, contents, mode) do
    with :ok <- write_tmp(path, contents, mode) do
      rename(tmp(path), path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_tmp(path, contents, mode) do
    tmp = tmp(path)
    _ = File.rm(tmp)

    with :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, mode),
         :ok <- File.write(tmp, contents) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:write, path, reason}}
    end
  end
end
