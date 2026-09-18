defmodule Portal.Accounts.WebAuthn do
  @moduledoc """
  WebAuthn configuration and challenge builder for Nerves Compatibility portal.

  Relying-party configuration (rp_id, origin) is explicit and never derived
  from the request. The host header is attacker-supplied, and the portal learns
  the scheme only from X-Forwarded-Proto behind Apache, so a derived origin
  fails closed the moment that header is misconfigured.

  The `wax_` library generates all challenge bytes; we never pass `bytes:` to
  avoid a replay window. User verification is required; attestation is none
  (BYOD passkey attestation, no verification). A 5-minute timeout helps users
  without local Bluetooth or NFC.
  """

  require Logger

  alias Portal.Accounts.{Passkey, Passkeys, User}

  @rp_name "Nerves Compatibility Tracker"
  @max_nickname_length 60

  # The Postgres unique index behind `Passkey`'s `:unique_credential_id`
  # identity. Matched by name rather than by message text so a phrasing change
  # in Ash cannot silently turn the duplicate contract back into a raw error.
  @credential_id_constraint "portal_passkeys_unique_credential_id_index"

  @spec opts(keyword()) :: keyword()
  def opts(extra \\ []) do
    config = Application.fetch_env!(:portal, __MODULE__)

    [
      rp_id: Keyword.fetch!(config, :rp_id),
      origin: Keyword.fetch!(config, :origin),
      user_verification: "required",
      attestation: "none",
      timeout: 300
    ]
    |> Keyword.merge(extra)
  end

  @spec rp_name() :: String.t()
  def rp_name, do: @rp_name

  @doc """
  A registration challenge plus the JSON-ready payload the browser needs.

  The caller stashes the `Wax.Challenge` in the signed session and sends the
  payload. `exclude_credentials` carries the ids the account already holds so
  the same authenticator cannot be enrolled twice; it is advisory — the
  duplicate check in `register/3` is what actually enforces it.
  """
  @spec registration_challenge(User.t()) :: {Wax.Challenge.t(), map()}
  def registration_challenge(%User{} = user) do
    challenge_opts = opts()
    challenge = Wax.new_registration_challenge(challenge_opts)

    payload = %{
      challenge: b64(challenge.bytes),
      rp_id: challenge.rp_id,
      rp_name: @rp_name,
      # The WebAuthn user handle. The UUID's 16 raw bytes, well inside the
      # 64-byte limit, and it is what a discoverable credential hands back at
      # login time to say who is signing in.
      user_handle: b64(Ecto.UUID.dump!(user.id)),
      user_name: user.username,
      # Derived, never re-littered: `opts/1` is the single source of truth for
      # timeout, user verification and attestation.
      timeout: Keyword.fetch!(challenge_opts, :timeout),
      exclude_credentials: Enum.map(Passkeys.list_for_user(user), &b64(&1.credential_id))
    }

    {challenge, payload}
  end

  @doc """
  Verifies an attestation and stores the resulting credential.
  """
  @spec register(User.t(), map(), Wax.Challenge.t()) :: {:ok, Passkey.t()} | {:error, term()}
  def register(%User{} = user, params, %Wax.Challenge{} = challenge) do
    with {:ok, attestation_object} <- decode(params["attestation_object"]),
         {:ok, client_data_json} <- decode(params["client_data_json"]),
         {:ok, {auth_data, _attestation}} <-
           verify_attestation(attestation_object, client_data_json, challenge),
         credential_data = auth_data.attested_credential_data,
         :ok <- ensure_unregistered(credential_data.credential_id) do
      user
      |> Passkeys.create(%{
        credential_id: credential_data.credential_id,
        public_key: :erlang.term_to_binary(credential_data.credential_public_key),
        sign_count: auth_data.sign_count,
        aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
        transports: transports(params["transports"]),
        nickname: nickname(params["nickname"])
      })
      |> normalize_create_error()
    end
  end

  # `wax_`'s CBOR decoder only unwraps `%CBOR.Tag{tag: :bytes}`; any other tag
  # number nested in the attested credential data reaches an `Enum.reduce/3`
  # over the bare `%CBOR.Tag{}` struct and raises `Protocol.UndefinedError`.
  # `attestation_object` is fully attacker-controlled, so that raise is
  # reachable by any authenticated user posting a hand-built payload. `with`
  # matches return values and does not catch exceptions, so the crash would
  # escape `register/3` and take the request with it.
  #
  # The rescue is deliberately wrapped around this one call rather than the
  # function body, so bugs in our own decoding, storage or validation still
  # surface as crashes instead of being laundered into a validation error.
  defp verify_attestation(attestation_object, client_data_json, challenge) do
    Wax.register(attestation_object, client_data_json, challenge)
  rescue
    exception ->
      log_attestation_crash(inspect(exception.__struct__), Exception.message(exception))
      {:error, :malformed_attestation}
  catch
    # Throws only. An `:exit` is a process-level signal — a lost database
    # connection, a shutdown — and converting one into "your passkey is
    # malformed" would blame the user for our outage and hide the real fault.
    :throw, value ->
      log_attestation_crash("throw", inspect(value))
      {:error, :malformed_attestation}
  end

  defp log_attestation_crash(kind, detail) do
    Logger.warning(
      "WebAuthn attestation verification crashed inside wax_ (#{kind}): #{detail}. " <>
        "Returning :malformed_attestation. If this is not a hand-crafted payload, " <>
        "it is a bug in the decode path rather than bad user input."
    )
  end

  defp ensure_unregistered(credential_id) do
    case Passkeys.get_by_credential_id(credential_id) do
      {:ok, _} -> {:error, :already_registered}
      :error -> :ok
    end
  end

  # `ensure_unregistered/1` is a read-then-write and therefore racy; the unique
  # index is what actually enforces one-registration-per-credential. When the
  # race is lost the database speaks instead of the guard, and without this the
  # caller would get a raw `%Ash.Error.Invalid{}` where every other path on this
  # branch returns the `:already_registered` sentinel.
  #
  # Public only so the regression test can drive the constraint path directly:
  # a genuine race cannot be forced inside the sandbox transaction, and the
  # guard above intercepts every duplicate that is reachable single-threaded.
  @doc false
  def normalize_create_error({:ok, passkey}), do: {:ok, passkey}

  def normalize_create_error({:error, %Ash.Error.Invalid{errors: errors} = error}) do
    if Enum.any?(errors, &credential_id_taken?/1) do
      {:error, :already_registered}
    else
      {:error, error}
    end
  end

  def normalize_create_error({:error, error}), do: {:error, error}

  defp credential_id_taken?(%{private_vars: private_vars}) when is_list(private_vars) do
    Keyword.get(private_vars, :constraint_type) == :unique and
      Keyword.get(private_vars, :constraint) == @credential_id_constraint
  end

  defp credential_id_taken?(_), do: false

  defp transports(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp transports(_), do: []

  defp nickname(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @max_nickname_length) do
      "" -> "Passkey"
      trimmed -> trimmed
    end
  end

  defp nickname(_), do: "Passkey"

  @doc false
  def b64(bin), do: Base.url_encode64(bin, padding: false)

  @doc false
  def decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :malformed_request}
    end
  end

  def decode(_), do: {:error, :malformed_request}
end
