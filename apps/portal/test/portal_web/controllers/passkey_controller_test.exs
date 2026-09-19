defmodule PortalWeb.PasskeyControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.WebAuthn
  alias Portal.Test.SoftwareAuthenticator

  @rp_id "localhost"
  @origin "http://localhost:4001"

  defp enrol(user) do
    authenticator = SoftwareAuthenticator.new(@rp_id)
    {challenge, _} = WebAuthn.registration_challenge(user)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    {:ok, _} =
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

    authenticator
  end

  defp assertion_body(user, response) do
    %{
      "credential_id" => WebAuthn.b64(response.credential_id),
      "authenticator_data" => WebAuthn.b64(response.authenticator_data),
      "signature" => WebAuthn.b64(response.signature),
      "client_data_json" => WebAuthn.b64(response.client_data_json),
      "user_handle" => WebAuthn.b64(Ecto.UUID.dump!(user.id))
    }
  end

  defp stashed_challenge(conn) do
    {challenge, _at} = get_session(conn, :passkey_login_challenge)
    challenge
  end

  test "the challenge endpoint names no credentials and stashes the challenge", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/challenge")

    body = json_response(conn, 200)
    assert body["rp_id"] == @rp_id
    assert body["timeout"] == 300
    assert is_binary(body["challenge"])
    refute Map.has_key?(body, "allow_credentials")
    assert stashed_challenge(conn)
  end

  test "a valid assertion signs in and hands back where to go", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 200)["redirect_to"] == ~p"/request-scan"
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :reauth_method) == :passkey
  end

  test "an admin lands on the admin page", %{conn: conn} do
    admin = admin_fixture()
    authenticator = enrol(admin)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(admin, response))

    assert json_response(conn, 200)["redirect_to"] == ~p"/admin"
  end

  test "a challenge works exactly once", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)

    first_response =
      SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    first = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, first_response))
    assert json_response(first, 200)["redirect_to"]

    # A fresh, otherwise-valid assertion over the same stashed challenge bytes,
    # with an incremented sign_count so clone detection (`check_sign_count/2`)
    # would let it through. This replay recycles from `first`'s response, so
    # it carries whatever cookie the server actually sent back after the
    # first login -- the one `take/2` should have stripped the challenge
    # from. The only thing that can refuse this one is the challenge having
    # been consumed.
    second_response =
      SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 2)

    replay = post(recycle(first), ~p"/auth/passkey/verify", assertion_body(user, second_response))

    assert json_response(replay, 401)["error"]
  end

  test "verifying with no challenge in the session is a 401", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)
    response = SoftwareAuthenticator.get(authenticator, :crypto.strong_rand_bytes(32), @origin)

    conn = post(conn, ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "a bad assertion is a 401 and grants nothing", %{conn: conn} do
    user = user_fixture()
    enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)

    impostor = SoftwareAuthenticator.new(@rp_id)
    response = SoftwareAuthenticator.get(impostor, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "an expired challenge is refused", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)
    {challenge, _} = WebAuthn.authentication_challenge()
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:passkey_login_challenge, {challenge, System.system_time(:second) - 301})
      |> post(~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end
end
