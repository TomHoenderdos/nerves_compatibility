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

  The caller stashes the `Wax.Challenge` with `PortalWeb.WebAuthnSession` and
  sends the payload. `exclude_credentials` carries the ids the account already holds so
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
      log_wax_crash("attestation", :malformed_attestation, exception)
      {:error, :malformed_attestation}
  catch
    # Throws only. An `:exit` is a process-level signal — a lost database
    # connection, a shutdown — and converting one into "your passkey is
    # malformed" would blame the user for our outage and hide the real fault.
    :throw, value ->
      log_wax_crash("attestation", :malformed_attestation, {:throw, value})
      {:error, :malformed_attestation}
  end

  defp log_wax_crash(stage, sentinel, thrown_or_raised) do
    {kind, detail} =
      case thrown_or_raised do
        {:throw, value} -> {"throw", inspect(value)}
        exception -> {inspect(exception.__struct__), Exception.message(exception)}
      end

    Logger.warning(
      "WebAuthn #{stage} verification crashed inside wax_ (#{kind}): #{detail}. " <>
        "Returning #{inspect(sentinel)}. If this is not a hand-crafted payload, " <>
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

  @doc """
  An authentication challenge for a passwordless sign-in.

  Deliberately omits `allow_credentials`: nobody has typed a username yet, so
  there is no account to narrow the list to. The authenticator picks a
  discoverable credential and returns a `userHandle` naming its owner.

  The caller stashes the `Wax.Challenge` with `PortalWeb.WebAuthnSession` and
  must consume it *before* calling `authenticate/2`, never after. Single use of
  the challenge is the only thing that stops a captured assertion being
  replayed — `check_sign_count/2` below is a cloned-authenticator heuristic and
  cannot stand in for it. That is why the challenge is held server-side rather
  than in the signed session: deleting a cookie only binds a client that
  chooses to send the new one. Verify first and consume afterwards and any
  assertion that leaks stays good for the whole five-minute window.
  """
  @spec authentication_challenge() :: {Wax.Challenge.t(), map()}
  def authentication_challenge do
    challenge_opts = opts()
    challenge = Wax.new_authentication_challenge(challenge_opts)

    payload = %{
      challenge: b64(challenge.bytes),
      rp_id: challenge.rp_id,
      # Derived, never re-littered: `opts/1` is the single source of truth for
      # the timeout, exactly as in `registration_challenge/1`.
      timeout: Keyword.fetch!(challenge_opts, :timeout)
    }

    {challenge, payload}
  end

  @doc """
  Verifies an assertion and returns the account it belongs to.

  Expects the challenge to have been consumed already — see
  `authentication_challenge/0`. This function verifies, it does not de-duplicate.
  """
  @spec authenticate(map(), Wax.Challenge.t()) ::
          {:ok, %{user: User.t(), passkey: Passkey.t()}} | {:error, term()}
  def authenticate(params, %Wax.Challenge{} = challenge) do
    with {:ok, credential_id} <- decode(params["credential_id"]),
         {:ok, auth_data_bin} <- decode(params["authenticator_data"]),
         {:ok, signature} <- decode(params["signature"]),
         {:ok, client_data_json} <- decode(params["client_data_json"]),
         {:ok, user} <- user_from_handle(params["user_handle"]),
         {:ok, passkey} <- passkey_for(user, credential_id),
         # Read the stored key out here, deliberately outside the rescue in
         # `verify_assertion/6`. `Passkeys.cose_key/1` is a `binary_to_term/2`
         # over a column we wrote; if it raises, our storage is corrupt and the
         # crash belongs in the logs as a crash, not laundered into
         # `:malformed_assertion` under a line blaming a hand-crafted payload.
         credentials = [{passkey.credential_id, Passkeys.cose_key(passkey)}],
         {:ok, auth_data} <-
           verify_assertion(
             credential_id,
             auth_data_bin,
             signature,
             client_data_json,
             challenge,
             credentials
           ),
         :ok <- verify_sign_count(passkey, auth_data.sign_count),
         {:ok, passkey} <- Passkeys.record_use(passkey, auth_data.sign_count) do
      {:ok, %{user: user, passkey: passkey}}
    end
  end

  # The same hazard as `verify_attestation/3`, and the same shape of fix.
  # `auth_data_bin` and `client_data_json` arrive from the client and are
  # parsed before anything checks the signature, so a hand-built pair reaches
  # `wax_`'s decoders on the strength of a valid credential id alone. Two
  # raises are reachable there, neither of them ours:
  #
  #   * `Wax.ClientData.parse_raw_json/1` `case`s on the JSON's "type" with no
  #     catch-all clause, so any string other than the two it knows raises
  #     `CaseClauseError`, and it calls `Base.url_decode64!/2` on "challenge".
  #   * authenticator data carrying the extension-data flag runs the same
  #     `Enum.reduce/3` over a bare `%CBOR.Tag{}` that bites registration.
  #
  # `with` matches return values and does not catch exceptions, so either one
  # would escape `authenticate/2` and take the request with it.
  #
  # A function-level `rescue` covers the whole body, so the body is nothing but
  # the one call and every argument is computed by the caller. That is what
  # keeps bugs in our own lookup, policy or storage crashing instead of being
  # laundered into a validation error — `credentials` in particular carries a
  # `binary_to_term/2` read of a column we wrote, and is built in
  # `authenticate/2` for exactly this reason. `:exit` is deliberately not
  # caught, for the reason given on `verify_attestation/3`.
  defp verify_assertion(
         credential_id,
         auth_data_bin,
         signature,
         client_data_json,
         challenge,
         credentials
       )
       when is_list(credentials) do
    Wax.authenticate(
      credential_id,
      auth_data_bin,
      signature,
      client_data_json,
      challenge,
      credentials
    )
  rescue
    exception ->
      log_wax_crash("assertion", :malformed_assertion, exception)
      {:error, :malformed_assertion}
  catch
    :throw, value ->
      log_wax_crash("assertion", :malformed_assertion, {:throw, value})
      {:error, :malformed_assertion}
  end

  @doc """
  The clone-detection rule.

  A stored count of zero means there is no baseline to compare against —
  either the credential has never been used, or the authenticator does not
  keep a counter at all. Apple's iCloud Keychain passkeys always report zero,
  and they are the authenticator most people will reach for first, so a naive
  "must increase" check would reject exactly the common case.

  Once a non-zero baseline exists the standard requires the counter to
  advance, so anything that does not is treated as a clone. The spec suggests
  flagging such an assertion; we refuse it, because this credential gates
  `/admin` and a flag nobody reads is not a control.
  """
  @spec check_sign_count(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :sign_count_regression}
  def check_sign_count(0, _incoming), do: :ok
  def check_sign_count(stored, incoming) when incoming > stored, do: :ok
  def check_sign_count(_stored, _incoming), do: {:error, :sign_count_regression}

  defp verify_sign_count(%Passkey{} = passkey, incoming) do
    case check_sign_count(passkey.sign_count, incoming) do
      :ok ->
        :ok

      {:error, :sign_count_regression} = error ->
        Logger.warning(
          "Passkey sign count regression for credential #{b64(passkey.credential_id)}: " <>
            "stored #{passkey.sign_count}, presented #{incoming}. Assertion refused."
        )

        error
    end
  end

  defp user_from_handle(handle) when is_binary(handle) do
    with {:ok, raw} <- decode(handle),
         {:ok, uuid} <- Ecto.UUID.load(raw),
         # `get_user/1` answers `{:ok, nil}` for an id that matches nobody, and
         # the user handle is as attacker-controlled as the rest of the
         # assertion. Matching `%User{}` is what keeps that nil out of
         # `passkey_for/2`, whose head would raise `FunctionClauseError` on it.
         {:ok, %User{} = user} <- Portal.Accounts.get_user(uuid) do
      {:ok, user}
    else
      _ -> {:error, :unknown_credential}
    end
  end

  defp user_from_handle(_), do: {:error, :missing_user_handle}

  defp passkey_for(%User{id: user_id}, credential_id) do
    case Passkeys.get_by_credential_id(credential_id) do
      {:ok, %Passkey{user_id: ^user_id} = passkey} -> {:ok, passkey}
      _ -> {:error, :unknown_credential}
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
