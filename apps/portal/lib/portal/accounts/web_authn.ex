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

  alias Portal.Accounts.{Passkey, Passkeys, User}

  @rp_name "Nerves Compatibility Tracker"
  @max_nickname_length 60

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
    challenge = Wax.new_registration_challenge(opts())

    payload = %{
      challenge: b64(challenge.bytes),
      rp_id: challenge.rp_id,
      rp_name: @rp_name,
      # The WebAuthn user handle. The UUID's 16 raw bytes, well inside the
      # 64-byte limit, and it is what a discoverable credential hands back at
      # login time to say who is signing in.
      user_handle: b64(Ecto.UUID.dump!(user.id)),
      user_name: user.username,
      timeout: 300,
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
           Wax.register(attestation_object, client_data_json, challenge),
         credential_data = auth_data.attested_credential_data,
         :ok <- ensure_unregistered(credential_data.credential_id) do
      Passkeys.create(user, %{
        credential_id: credential_data.credential_id,
        public_key: :erlang.term_to_binary(credential_data.credential_public_key),
        sign_count: auth_data.sign_count,
        aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
        transports: transports(params["transports"]),
        nickname: nickname(params["nickname"])
      })
    end
  end

  defp ensure_unregistered(credential_id) do
    case Passkeys.get_by_credential_id(credential_id) do
      {:ok, _} -> {:error, :already_registered}
      :error -> :ok
    end
  end

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
