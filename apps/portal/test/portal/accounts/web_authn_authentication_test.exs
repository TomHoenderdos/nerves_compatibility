defmodule Portal.Accounts.WebAuthnAuthenticationTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Passkeys, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp enrolled_user(opts \\ []) do
    user = user_fixture()
    authenticator = SoftwareAuthenticator.new(@rp_id, opts)
    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    {:ok, passkey} =
      WebAuthn.register(
        user,
        %{
          "nickname" => "laptop",
          "attestation_object" => WebAuthn.b64(response.attestation_object),
          "client_data_json" => WebAuthn.b64(response.client_data_json),
          "transports" => []
        },
        challenge
      )

    {user, authenticator, passkey}
  end

  defp assertion_params(user, response) do
    %{
      "credential_id" => WebAuthn.b64(response.credential_id),
      "authenticator_data" => WebAuthn.b64(response.authenticator_data),
      "signature" => WebAuthn.b64(response.signature),
      "client_data_json" => WebAuthn.b64(response.client_data_json),
      "user_handle" => WebAuthn.b64(Ecto.UUID.dump!(user.id))
    }
  end

  test "a discoverable credential signs in with no username typed" do
    {user, authenticator, _passkey} = enrolled_user()
    {challenge, payload} = WebAuthn.authentication_challenge()

    # Discoverable credentials: the server names no credentials, the
    # authenticator picks one and says who it belongs to.
    assert payload.rp_id == @rp_id
    refute Map.has_key?(payload, :allow_credentials)

    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    assert {:ok, %{user: signed_in, passkey: passkey}} =
             WebAuthn.authenticate(assertion_params(user, response), challenge)

    assert signed_in.id == user.id
    assert passkey.sign_count == 1
    assert passkey.last_used_at
  end

  test "an assertion for the wrong origin is rejected" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, "https://evil.example")

    assert {:error, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
  end

  test "an assertion answering a different challenge is rejected" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()

    response =
      SoftwareAuthenticator.get(authenticator, :crypto.strong_rand_bytes(32), @origin,
        sign_count: 1
      )

    assert {:error, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
  end

  test "an assertion signed by a different key is rejected" do
    {user, _authenticator, passkey} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()

    impostor = SoftwareAuthenticator.new(@rp_id, credential_id: passkey.credential_id)
    response = SoftwareAuthenticator.get(impostor, challenge.bytes, @origin, sign_count: 1)

    assert {:error, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
  end

  test "an unknown credential id is rejected" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    params =
      user
      |> assertion_params(response)
      |> Map.put("credential_id", WebAuthn.b64(:crypto.strong_rand_bytes(32)))

    assert WebAuthn.authenticate(params, challenge) == {:error, :unknown_credential}
  end

  test "a credential id belonging to someone else's account is rejected" do
    {_user, authenticator, _} = enrolled_user()
    stranger = user_fixture()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    assert WebAuthn.authenticate(assertion_params(stranger, response), challenge) ==
             {:error, :unknown_credential}
  end

  test "a missing user handle is rejected rather than guessed at" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    params = user |> assertion_params(response) |> Map.put("user_handle", nil)

    assert WebAuthn.authenticate(params, challenge) == {:error, :missing_user_handle}
  end

  test "a user handle naming nobody is rejected, not crashed on" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    # A well-formed handle for an account that does not exist. `get_user/1`
    # answers `{:ok, nil}` here, and a nil reaching `passkey_for/2` would raise
    # `FunctionClauseError` on its `%User{}` head.
    params =
      user
      |> assertion_params(response)
      |> Map.put("user_handle", WebAuthn.b64(Ecto.UUID.dump!(Ecto.UUID.generate())))

    assert WebAuthn.authenticate(params, challenge) == {:error, :unknown_credential}
  end

  test "malformed base64 is an error, not a crash" do
    {_user, _authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()

    params = %{
      "credential_id" => "!!!not base64!!!",
      "authenticator_data" => "!!!",
      "signature" => "!!!",
      "client_data_json" => "!!!",
      "user_handle" => "!!!"
    }

    assert WebAuthn.authenticate(params, challenge) == {:error, :malformed_request}
  end

  test "a hand-built client data JSON is an error, not a crash" do
    {user, authenticator, _} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    # `Wax.ClientData.parse_raw_json/1` `case`s on "type" with no catch-all
    # clause, so an unknown type raises `CaseClauseError`. Nothing has checked
    # the signature by the time it gets there — a valid credential id and
    # well-formed authenticator data are enough to reach it — and `with`
    # matches return values rather than catching exceptions, so without the
    # rescue the raise escapes and takes the request with it.
    hostile =
      Jason.encode!(%{
        "type" => "webauthn.craft",
        "challenge" => Base.url_encode64(challenge.bytes, padding: false),
        "origin" => @origin,
        "crossOrigin" => false
      })

    params =
      user
      |> assertion_params(response)
      |> Map.put("client_data_json", WebAuthn.b64(hostile))

    assert WebAuthn.authenticate(params, challenge) == {:error, :malformed_assertion}
  end

  test "a corrupt stored public key crashes instead of reading as a bad assertion" do
    {user, authenticator, passkey} = enrolled_user()
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    # This is our column, not the client's payload. `Passkeys.cose_key/1` runs
    # `binary_to_term(bin, [:safe])` over it and raises on anything that is not
    # a term. That read sits outside the rescue around `Wax.authenticate/6` on
    # purpose: silent storage corruption on the credential set that gates
    # /admin must not spend forever in the logs as `:malformed_assertion`
    # under a line blaming a hand-crafted payload.
    Ecto.Adapters.SQL.query!(
      Portal.Repo,
      "UPDATE portal_passkeys SET public_key = $1 WHERE id = $2",
      ["not an erlang term", Ecto.UUID.dump!(passkey.id)]
    )

    assert_raise ArgumentError, fn ->
      WebAuthn.authenticate(assertion_params(user, response), challenge)
    end
  end

  test "sign count: zero stays zero, which is what iCloud Keychain does" do
    assert WebAuthn.check_sign_count(0, 0) == :ok
    assert WebAuthn.check_sign_count(0, 5) == :ok
  end

  test "sign count: increasing is fine, standing still or going backwards is not" do
    assert WebAuthn.check_sign_count(4, 5) == :ok
    assert WebAuthn.check_sign_count(5, 5) == {:error, :sign_count_regression}
    assert WebAuthn.check_sign_count(9, 4) == {:error, :sign_count_regression}
  end

  test "an assertion whose counter went backwards is refused end to end" do
    {user, authenticator, passkey} = enrolled_user()

    {first, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, first.bytes, @origin, sign_count: 7)
    {:ok, _} = WebAuthn.authenticate(assertion_params(user, response), first)

    {second, _} = WebAuthn.authentication_challenge()
    replay = SoftwareAuthenticator.get(authenticator, second.bytes, @origin, sign_count: 3)

    assert WebAuthn.authenticate(assertion_params(user, replay), second) ==
             {:error, :sign_count_regression}

    {:ok, unchanged} = Passkeys.get_by_credential_id(passkey.credential_id)
    assert unchanged.sign_count == 7
  end

  test "an iCloud-style authenticator that always reports zero keeps working" do
    {user, authenticator, _} = enrolled_user(sign_count: 0)

    for _ <- 1..3 do
      {challenge, _} = WebAuthn.authentication_challenge()
      response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 0)

      assert {:ok, _} = WebAuthn.authenticate(assertion_params(user, response), challenge)
    end
  end

  test "the challenge payload timeout is derived from opts, not re-littered" do
    {_challenge, payload} = WebAuthn.authentication_challenge()

    assert payload.timeout == Keyword.fetch!(WebAuthn.opts(), :timeout)
  end
end
