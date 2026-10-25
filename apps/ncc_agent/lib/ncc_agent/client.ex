defmodule NccAgent.Client do
  @moduledoc """
  The agent's side of the portal's `/builder/v1` API.

  `fetch_ca/1` and `enroll/6` run before the agent has an identity; every
  other call goes through the mTLS `Req` that `new/1` builds from the
  identity in the data dir. Every request sends `x-ncc-agent-version`.

  Finch pools are keyed on the connect options, which name the identity's
  files rather than their contents, so after a renewal `NccAgent.Identity`
  drops the old pool (`drop_pool/1`) along with the old `Req`.
  """

  alias NccAgent.{Config, Version}

  @api "/builder/v1"
  @chunk 262_144

  @type error :: {:error, term()}

  @doc """
  Fetches the portal's CA certificate without verifying the server: there
  is no trust anchor yet. `verify_ca/2` against the enrolment token's
  prefix is what authenticates it.
  """
  @spec fetch_ca(String.t()) :: {:ok, String.t()} | error()
  def fetch_ca(portal_url) do
    [
      base_url: portal_url,
      url: @api <> "/ca.pem",
      headers: version_header(),
      retry: false,
      decode_body: false,
      connect_options: [transport_opts: [verify: :verify_none]]
    ]
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: pem}} when is_binary(pem) -> {:ok, pem}
      other -> error(other)
    end
  end

  @doc "Whether the sha256 of the PEM's certificate DER starts with the token's prefix."
  @spec verify_ca(String.t(), String.t()) :: :ok | {:error, :ca_mismatch}
  def verify_ca(pem, prefix)
      when is_binary(pem) and is_binary(prefix) and byte_size(prefix) >= 16 do
    with [{:Certificate, der, :not_encrypted}] <- safe_pem_decode(pem),
         true <- der |> fingerprint() |> String.starts_with?(prefix) do
      :ok
    else
      _ -> {:error, :ca_mismatch}
    end
  end

  def verify_ca(_pem, _prefix), do: {:error, :ca_mismatch}

  @doc "Exchanges the enrolment token and a CSR for a client certificate."
  @spec enroll(String.t(), Path.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok,
           %{cert_pem: String.t(), expires_at: DateTime.t(), builder_id: term(), name: String.t()}}
          | error()
  def enroll(portal_url, ca_path, token, csr_pem, version, slots) do
    [
      base_url: portal_url,
      url: @api <> "/enroll",
      headers: [{"x-ncc-agent-version", version}],
      retry: false,
      receive_timeout: 60_000,
      json: %{token: token, csr_pem: csr_pem, agent_version: version, slots: slots},
      connect_options: [
        transport_opts: [verify: :verify_peer, cacertfile: String.to_charlist(ca_path)]
      ]
    ]
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: 201, body: %{"certificate_pem" => pem} = body}} ->
        with {:ok, expires_at} <- expires_at(body["expires_at"]) do
          {:ok,
           %{
             cert_pem: pem,
             expires_at: expires_at,
             builder_id: body["builder_id"],
             name: body["name"]
           }}
        end

      other ->
        error(other)
    end
  end

  @doc "The mTLS `Req` for the identity in `config`'s data dir."
  @spec new(Config.t()) :: Req.Request.t()
  def new(config) do
    %URI{host: host} = URI.parse(config.portal_url)

    Req.new(
      base_url: config.portal_url,
      headers: version_header(),
      retry: false,
      receive_timeout: 60_000,
      connect_options: [
        transport_opts: [
          verify: :verify_peer,
          cacertfile: String.to_charlist(Config.path(config, :ca)),
          certfile: String.to_charlist(Config.path(config, :cert)),
          keyfile: String.to_charlist(Config.path(config, :key)),
          server_name_indication: String.to_charlist(host),
          depth: 2
        ]
      ]
    )
  end

  @doc """
  Stops the Finch pool `req` uses, so the next request through a rebuilt
  `Req` opens fresh connections with the files' current contents.
  """
  @spec drop_pool(Req.Request.t()) :: :ok
  def drop_pool(%Req.Request{} = req) do
    name = req.options |> Req.Finch.pool_options() |> Req.Finch.pool_name()

    case Process.whereis(name) do
      nil -> :ok
      pid -> _ = DynamicSupervisor.terminate_child(Req.FinchSupervisor, pid)
    end

    # ssl caches PEM files by name; the renewed files keep their names.
    :ssl.clear_pem_cache()
  end

  @doc "Renews the certificate for a new CSR."
  @spec renew(Req.Request.t(), String.t()) ::
          {:ok, %{cert_pem: String.t(), expires_at: DateTime.t()}}
          | {:error, :too_early}
          | error()
  def renew(req, csr_pem) do
    case Req.post(req, url: @api <> "/renew", json: %{csr_pem: csr_pem}) do
      {:ok, %Req.Response{status: 200, body: %{"certificate_pem" => pem} = body}} ->
        with {:ok, expires_at} <- expires_at(body["expires_at"]) do
          {:ok, %{cert_pem: pem, expires_at: expires_at}}
        end

      {:ok, %Req.Response{status: 425}} ->
        {:error, :too_early}

      other ->
        error(other)
    end
  end

  @doc "Reports the agent's version, egress ruleset state and free slots."
  @spec status(Req.Request.t(), String.t(), non_neg_integer()) :: :ok | error()
  def status(req, egress, free_slots) do
    body = %{agent_version: Version.current(), egress: egress, free_slots: free_slots}

    case Req.post(req, url: @api <> "/status", json: body) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc """
  Long-polls for a job. `:none` when the portal has nothing (204); an agent
  reporting its egress ruleset missing gets `{:error, :egress_missing}`.
  """
  @spec claim(Req.Request.t(), non_neg_integer(), String.t()) :: {:ok, map()} | :none | error()
  def claim(req, free_slots, egress) do
    body = %{agent_version: Version.current(), free_slots: free_slots, egress: egress}

    case Req.post(req, url: @api <> "/jobs/claim", json: body, receive_timeout: 40_000) do
      {:ok, %Req.Response{status: 200, body: %{} = claim}} ->
        {:ok, claim}

      {:ok, %Req.Response{status: 204}} ->
        :none

      {:ok, %Req.Response{status: 409, body: %{"error" => "egress_missing"}}} ->
        {:error, :egress_missing}

      other ->
        error(other)
    end
  end

  @spec heartbeat(Req.Request.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | error()
  def heartbeat(req, lease_id, phase, log_tail) do
    case Req.post(req,
           url: job(lease_id, "/heartbeat"),
           json: %{phase: phase, log_tail: log_tail}
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc "Which of `shas` the portal has not got for this lease."
  @spec missing(Req.Request.t(), String.t(), [String.t()]) :: {:ok, [String.t()]} | error()
  def missing(req, lease_id, shas) do
    case Req.post(req, url: job(lease_id, "/files/missing"), json: %{shas: shas}) do
      {:ok, %Req.Response{status: 200, body: %{"missing" => missing}}} when is_list(missing) ->
        {:ok, missing}

      other ->
        error(other)
    end
  end

  @doc """
  Streams a tar batch of files to the portal. Entries the portal refused
  (hash mismatch) come back as `{:error, {:bad_entries, shas}}`.
  """
  @spec upload(Req.Request.t(), String.t(), Path.t()) :: {:ok, map()} | error()
  # `tar_path` is a batch the agent itself wrote under its scratch dir.
  # sobelow_skip ["Traversal.FileModule"]
  def upload(req, lease_id, tar_path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(tar_path) do
      req
      |> Req.put(
        url: job(lease_id, "/files"),
        headers: [
          {"content-type", "application/x-tar"},
          {"content-length", Integer.to_string(size)}
        ],
        body: File.stream!(tar_path, @chunk)
      )
      |> case do
        {:ok, %Req.Response{status: 200, body: %{"stored" => _, "bad" => _} = body}} ->
          {:ok, body}

        {:ok, %Req.Response{status: 422, body: %{"error" => "bad_entries", "bad" => bad}}} ->
          {:error, {:bad_entries, bad}}

        other ->
          error(other)
      end
    end
  end

  @doc """
  Completes the lease with the worker's exit code and whichever of
  `result` (result.json), `logs` (logs.tar.gz) and `runner_log` exist.
  """
  @spec complete(Req.Request.t(), String.t(), integer(), %{optional(atom()) => Path.t() | nil}) ::
          {:ok, map()} | error()
  def complete(req, lease_id, exit_code, parts) do
    form =
      [exit_code: Integer.to_string(exit_code)] ++
        part(parts, :result, "result.json") ++
        part(parts, :logs, "logs.tar.gz") ++ part(parts, :runner_log, "runner.log")

    case Req.post(req, url: job(lease_id, "/complete"), form_multipart: form) do
      {:ok, %Req.Response{status: 202, body: %{} = body}} -> {:ok, body}
      other -> error(other)
    end
  end

  @doc "Lowercase hex sha256 of a DER."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  # The parts are the worker's outputs in the agent's own scratch dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp part(parts, key, filename) do
    case Map.get(parts, key) do
      nil -> []
      path -> [{key, {File.stream!(path, @chunk), filename: filename}}]
    end
  end

  defp job(lease_id, suffix),
    do: @api <> "/jobs/" <> URI.encode(lease_id, &URI.char_unreserved?/1) <> suffix

  defp version_header, do: [{"x-ncc-agent-version", Version.current()}]

  defp safe_pem_decode(pem) do
    :public_key.pem_decode(pem)
  rescue
    _ -> []
  end

  defp expires_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :bad_expires_at}
    end
  end

  defp expires_at(_), do: {:error, :bad_expires_at}

  defp error({:ok, %Req.Response{status: 409, body: %{"error" => "lease_not_held"}}}),
    do: {:error, :lease_not_held}

  defp error({:ok, %Req.Response{status: status, body: %{"error" => reason}}}),
    do: {:error, {:http, status, reason}}

  defp error({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp error({:error, reason}), do: {:error, reason}
end
