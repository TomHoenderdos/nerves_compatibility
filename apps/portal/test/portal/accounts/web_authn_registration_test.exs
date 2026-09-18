defmodule Portal.Accounts.WebAuthnRegistrationTest do
  use Portal.DataCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Passkeys, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp registration_params(response, extra \\ %{}) do
    Map.merge(
      %{
        "nickname" => "laptop",
        "attestation_object" => Base.url_encode64(response.attestation_object, padding: false),
        "client_data_json" => Base.url_encode64(response.client_data_json, padding: false),
        "transports" => ["internal"]
      },
      extra
    )
  end

  test "a real attestation round-trip registers the credential" do
    user = user_fixture()
    {challenge, payload} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert {:ok, passkey} = WebAuthn.register(user, registration_params(response), challenge)

    assert passkey.credential_id == authenticator.credential_id
    assert passkey.nickname == "laptop"
    assert passkey.transports == ["internal"]
    assert passkey.user_id == user.id
    assert is_map(Passkeys.cose_key(passkey))
    assert Passkeys.count_for_user(user) == 1

    assert payload.rp_id == @rp_id
    assert payload.user_name == user.username
    assert payload.user_handle == Base.url_encode64(Ecto.UUID.dump!(user.id), padding: false)
    assert payload.exclude_credentials == []
  end

  test "the challenge payload lists already-registered credentials to exclude" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)
    {:ok, _} = WebAuthn.register(user, registration_params(response), challenge)

    {_next_challenge, payload} = WebAuthn.registration_challenge(user)

    assert payload.exclude_credentials == [
             Base.url_encode64(authenticator.credential_id, padding: false)
           ]
  end

  test "an attestation signed against a different origin is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)

    response =
      SoftwareAuthenticator.create(authenticator, challenge.bytes, "https://evil.example")

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
    assert Passkeys.count_for_user(user) == 0
  end

  test "an attestation for a different relying party is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new("evil.example")
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
  end

  test "an attestation answering a different challenge is rejected" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)
    authenticator = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.create(authenticator, :crypto.strong_rand_bytes(32), @origin)

    assert {:error, _} = WebAuthn.register(user, registration_params(response), challenge)
  end

  test "the same credential cannot be registered twice, even by another account" do
    user = user_fixture()
    stranger = user_fixture()
    authenticator = SoftwareAuthenticator.new(@rp_id)

    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)
    {:ok, _} = WebAuthn.register(user, registration_params(response), challenge)

    {challenge2, _} = WebAuthn.registration_challenge(stranger)
    response2 = SoftwareAuthenticator.create(authenticator, challenge2.bytes, @origin)

    assert WebAuthn.register(stranger, registration_params(response2), challenge2) ==
             {:error, :already_registered}
  end

  test "a blank nickname gets a default and an overlong one is truncated" do
    user = user_fixture()

    {challenge, _} = WebAuthn.registration_challenge(user)

    response =
      SoftwareAuthenticator.create(SoftwareAuthenticator.new(@rp_id), challenge.bytes, @origin)

    {:ok, blank} =
      WebAuthn.register(user, registration_params(response, %{"nickname" => "   "}), challenge)

    assert blank.nickname == "Passkey"

    {challenge2, _} = WebAuthn.registration_challenge(user)

    response2 =
      SoftwareAuthenticator.create(SoftwareAuthenticator.new(@rp_id), challenge2.bytes, @origin)

    {:ok, long} =
      WebAuthn.register(
        user,
        registration_params(response2, %{"nickname" => String.duplicate("x", 200)}),
        challenge2
      )

    assert String.length(long.nickname) == 60
  end

  test "malformed base64 is an error, not a crash" do
    user = user_fixture()
    {challenge, _} = WebAuthn.registration_challenge(user)

    params = %{
      "nickname" => "k",
      "attestation_object" => "!!!not base64!!!",
      "client_data_json" => "!!!",
      "transports" => []
    }

    assert WebAuthn.register(user, params, challenge) == {:error, :malformed_request}
  end
end
