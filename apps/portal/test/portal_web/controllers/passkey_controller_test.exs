defmodule PortalWeb.PasskeyControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.WebAuthn
  alias Portal.Test.SoftwareAuthenticator
  alias PortalWeb.WebAuthnSession

  @rp_id "localhost"
  @origin "http://localhost:4001"

  # Every test speaks the transport the browser speaks. `webauthn.js` sends
  # `accept: application/json`, and `build_conn/0` sends no Accept header at
  # all -- which is how these routes sat behind `plug :accepts, ["html"]`
  # answering 406 to every real client while the suite stayed green.
  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

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

  # The session now carries only an id; the challenge itself is server-side.
  defp stashed_id(conn), do: get_session(conn, :passkey_login_challenge)

  defp stashed_challenge(conn) do
    [{_id, challenge, _at}] = :ets.lookup(WebAuthnSession.table(), stashed_id(conn))
    challenge
  end

  # Ages the stored row rather than the session, because the session no longer
  # holds a timestamp to forge. `offset` is added to the stored `at`.
  defp age_stash(conn, offset) do
    id = stashed_id(conn)
    [{^id, challenge, at}] = :ets.lookup(WebAuthnSession.table(), id)
    :ets.insert(WebAuthnSession.table(), {id, challenge, at + offset})
    conn
  end

  test "the challenge endpoint names no credentials and stashes the challenge", %{conn: conn} do
    conn = post(conn, ~p"/auth/passkey/challenge")

    body = json_response(conn, 200)
    assert body["rp_id"] == @rp_id
    assert body["timeout"] == 300
    assert is_binary(body["challenge"])
    refute Map.has_key?(body, "allow_credentials")

    # The session holds an opaque id, not the challenge, and the id resolves
    # server-side to the bytes the browser was handed.
    assert byte_size(stashed_id(conn)) == 16
    assert WebAuthn.b64(stashed_challenge(conn).bytes) == body["challenge"]
  end

  test "the browser's Accept header is honoured", %{conn: conn} do
    # `:browser` would raise `Phoenix.NotAcceptableError` here. This pins the
    # two routes to a pipeline that accepts the JSON their client asks for.
    conn = post(conn, ~p"/auth/passkey/challenge")

    assert json_response(conn, 200)["rp_id"] == @rp_id
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
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
    assert get_session(conn, :user_id) == admin.id
    # The half of the admin gate that enrolment cannot supply. Flip this to
    # any other method and `RequireAdmin` refuses the session.
    assert get_session(conn, :login_method) == :passkey
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

    # A fresh, otherwise-valid assertion over the same challenge bytes, with an
    # incremented sign_count so clone detection (`check_sign_count/2`) would
    # let it through. The only thing that can refuse this is the challenge
    # having been consumed. This is the honest-client half: it follows the
    # server's cookie updates.
    second_response =
      SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 2)

    replay = post(recycle(first), ~p"/auth/passkey/verify", assertion_body(user, second_response))

    assert json_response(replay, 401)["error"]
  end

  test "a challenge is spent even for a client that kept the old cookie", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)

    first =
      post(
        recycle(conn),
        ~p"/auth/passkey/verify",
        assertion_body(
          user,
          SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)
        )
      )

    assert json_response(first, 200)["redirect_to"]

    # The adversarial half: this replays the *pre-verify* conn, so it presents
    # the session id the challenge was stashed under, exactly as someone who
    # captured that request would. The server, not the client's cookie jar,
    # has to refuse it -- which is only true because the challenge lives in
    # ETS and `take/2` deleted the row.
    replay =
      post(
        recycle(conn),
        ~p"/auth/passkey/verify",
        assertion_body(
          user,
          SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 2)
        )
      )

    assert json_response(replay, 401)["error"]
    refute get_session(replay, :user_id)
  end

  test "verifying with no challenge in the session is a 401", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)
    response = SoftwareAuthenticator.get(authenticator, :crypto.strong_rand_bytes(32), @origin)

    conn = post(conn, ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "an assertion signed by another key is a 401 and grants nothing", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)

    # Same credential id, different private key: the lookup in `passkey_for/2`
    # succeeds, so the refusal comes from signature verification inside `wax_`
    # rather than from an unknown credential id (which the test above covers).
    impostor = SoftwareAuthenticator.new(@rp_id, credential_id: authenticator.credential_id)
    response = SoftwareAuthenticator.get(impostor, challenge.bytes, @origin, sign_count: 1)

    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "an expired challenge is refused", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn = age_stash(conn, -(WebAuthnSession.ttl_seconds() + 1))
    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end

  test "a future-dated challenge is refused", %{conn: conn} do
    user = user_fixture()
    authenticator = enrol(user)

    conn = post(conn, ~p"/auth/passkey/challenge")
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    # A clock stepped backwards between `put/3` and `take/2` -- an NTP
    # correction -- would otherwise leave this row valid indefinitely.
    conn = age_stash(conn, 60)
    conn = post(recycle(conn), ~p"/auth/passkey/verify", assertion_body(user, response))

    assert json_response(conn, 401)["error"]
    refute get_session(conn, :user_id)
  end
end
