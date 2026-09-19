defmodule PortalWeb.SecurityControllerTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.{Mfa, Passkeys, RecoveryCodes, Totp, WebAuthn}
  alias Portal.Test.SoftwareAuthenticator
  alias PortalWeb.WebAuthnSession

  @password "correct horse battery staple"
  @rp_id "localhost"
  @origin "http://localhost:4001"
  @at ~U[2026-09-18 12:00:00.000000Z]
  @registration_key :passkey_registration_challenge

  # A displayed recovery code: four Base32 groups of four.
  @code ~r/[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}/

  defp sign_in(conn, user, method \\ :password) do
    conn
    |> init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second))
  end

  defp stale_sign_in(conn, user, method \\ :password) do
    conn
    |> init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:reauth_method, method)
    |> put_session(:reauth_at, System.system_time(:second) - 601)
  end

  # The four `fetch`-driven routes answer JSON, so the tests that exercise them
  # must send the Accept header a browser sends. `build_conn/0` sends none at
  # all, which is exactly how a route parked behind `plug :accepts, ["html"]`
  # can 406 every real client while the suite stays green. Applied per request
  # rather than in `setup`, because most routes on this page are HTML form
  # posts that must keep exercising the HTML path.
  defp asks_for_json(conn), do: put_req_header(conn, "accept", "application/json")

  defp add_passkey(user) do
    {:ok, passkey} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    passkey
  end

  defp add_totp(user) do
    {:ok, %{secret: secret}} = Totp.start_enrolment(user)
    :ok = Totp.confirm(user, NimbleTOTP.verification_code(secret, time: @at), @at)
    secret
  end

  # The session carries only a 16-byte id; the challenge itself lives in
  # `WebAuthnSession`'s ETS table. Read it rather than `take/2`, which would
  # consume the challenge this test still needs.
  defp stashed_challenge(conn) do
    id = get_session(conn, @registration_key)
    [{^id, challenge, _at}] = :ets.lookup(WebAuthnSession.table(), id)
    challenge
  end

  # A passkey the software authenticator can actually sign with, unlike the
  # dummy row `add_passkey/1` writes.
  defp enrol(user) do
    authenticator = SoftwareAuthenticator.new(@rp_id)
    {challenge, _payload} = WebAuthn.registration_challenge(user)
    created = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    {:ok, _passkey} =
      WebAuthn.register(
        user,
        %{
          "nickname" => "enrolled",
          "attestation_object" => WebAuthn.b64(created.attestation_object),
          "client_data_json" => WebAuthn.b64(created.client_data_json),
          "transports" => []
        },
        challenge
      )

    authenticator
  end

  defp reauth_challenge(conn) do
    conn = post(conn, ~p"/settings/security/reauth/passkey/challenge")
    assert json_response(conn, 200)["rp_id"] == @rp_id

    id = get_session(conn, :passkey_reauth_challenge)
    [{^id, challenge, _at}] = :ets.lookup(WebAuthnSession.table(), id)

    {conn, challenge}
  end

  defp assertion_body(user, assertion) do
    %{
      "credential_id" => WebAuthn.b64(assertion.credential_id),
      "authenticator_data" => WebAuthn.b64(assertion.authenticator_data),
      "signature" => WebAuthn.b64(assertion.signature),
      "client_data_json" => WebAuthn.b64(assertion.client_data_json),
      "user_handle" => WebAuthn.b64(Ecto.UUID.dump!(user.id))
    }
  end

  defp fresh_reauth?(conn, user) do
    Mfa.reauth_fresh?(user, get_session(conn, :reauth_method), get_session(conn, :reauth_at))
  end

  # Scoped to the one list that renders them, not the whole body: a passkey's
  # UUID is rendered in its delete form, and `@code` matches a stretch of
  # hex-plus-dashes roughly 2% of the time, which is a flake, not a test.
  # `query/2` rather than `filter/2` — `filter/2` narrows the current node set
  # and would never see past `<html>`.
  defp shown_codes(body) do
    body
    |> LazyHTML.from_document()
    |> LazyHTML.query("#new-recovery-codes li")
    |> LazyHTML.text()
  end

  test "the page lists factors and is reachable without a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> stale_sign_in(user) |> get(~p"/settings/security")

    body = html_response(conn, 200)
    assert body =~ "laptop"
    assert body =~ "Security"
  end

  test "signing out of the window blocks a factor change", %{conn: conn} do
    user = user_fixture(%{password: @password})
    passkey = add_passkey(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{passkey.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(user) == 1
  end

  test "the password re-authorises while the account holds no factor", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn =
      conn
      |> stale_sign_in(user)
      |> post(~p"/settings/security/reauth", %{"method" => "password", "credential" => @password})

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :password
  end

  test "the password stops re-authorising once a passkey exists", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> post(~p"/settings/security/reauth", %{"method" => "password", "credential" => @password})

    assert html_response(conn, 200) =~ "passkey"
    refute get_session(conn, :reauth_method) == :password
  end

  test "a recovery code re-authorises and is spent", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)
    {:ok, [code | _]} = RecoveryCodes.generate(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> post(~p"/settings/security/reauth", %{
        "method" => "recovery_code",
        "credential" => code
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :recovery_code
    assert RecoveryCodes.remaining(user) == 9
  end

  test "a TOTP code re-authorises a TOTP-only account", %{conn: conn} do
    user = user_fixture(%{password: @password})
    secret = add_totp(user)

    conn =
      conn
      |> stale_sign_in(user, :totp)
      |> post(~p"/settings/security/reauth", %{
        "method" => "totp",
        "credential" => NimbleTOTP.verification_code(secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :totp
  end

  test "the browser's Accept header is honoured on the JSON routes", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn =
      conn
      |> sign_in(user)
      |> asks_for_json()
      |> post(~p"/settings/security/passkeys/challenge")

    # Behind `:authenticated` this raises `Phoenix.NotAcceptableError` before
    # the controller runs. That is the whole point of `:authenticated_json`.
    assert json_response(conn, 200)["rp_id"] == @rp_id
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "registering a passkey works end to end with a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    authenticator = SoftwareAuthenticator.new(@rp_id)

    conn =
      conn
      |> sign_in(user)
      |> asks_for_json()
      |> post(~p"/settings/security/passkeys/challenge")

    payload = json_response(conn, 200)
    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    assert payload["user_name"] == user.username

    conn =
      post(recycle(conn), ~p"/settings/security/passkeys", %{
        "nickname" => "yubikey",
        "attestation_object" => WebAuthn.b64(response.attestation_object),
        "client_data_json" => WebAuthn.b64(response.client_data_json),
        "transports" => ["usb"]
      })

    assert json_response(conn, 200)["ok"]
    assert Passkeys.count_for_user(user) == 1
  end

  test "the registration challenge is refused without a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn =
      conn
      |> stale_sign_in(user, :passkey)
      |> asks_for_json()
      |> post(~p"/settings/security/passkeys/challenge")

    assert json_response(conn, 403)["error"]
    refute get_session(conn, @registration_key)
  end

  test "a passkey re-authorises the window", %{conn: conn} do
    user = user_fixture(%{password: @password})
    authenticator = enrol(user)

    conn = conn |> stale_sign_in(user, :passkey) |> asks_for_json()
    {conn, challenge} = reauth_challenge(conn)

    assertion = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn =
      post(recycle(conn), ~p"/settings/security/reauth/passkey", assertion_body(user, assertion))

    assert json_response(conn, 200)["ok"]
    assert fresh_reauth?(conn, user)
  end

  test "another account's passkey does not re-authorise this session", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)
    stranger = user_fixture()
    authenticator = enrol(stranger)

    conn = conn |> stale_sign_in(user, :passkey) |> asks_for_json()
    {conn, challenge} = reauth_challenge(conn)

    assertion = SoftwareAuthenticator.get(authenticator, challenge.bytes, @origin, sign_count: 1)

    conn =
      post(
        recycle(conn),
        ~p"/settings/security/reauth/passkey",
        assertion_body(stranger, assertion)
      )

    assert json_response(conn, 401)["error"]
    refute fresh_reauth?(conn, user)
  end

  test "TOTP enrolment needs one working code before it counts", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")
    body = html_response(conn, 200)
    assert body =~ "otpauth://totp/"

    refute Totp.confirmed?(user)

    {:ok, stored} = Totp.get_secret(user)

    conn =
      post(recycle(conn), ~p"/settings/security/totp/confirm", %{
        "code" => NimbleTOTP.verification_code(stored.secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert Totp.confirmed?(user)
  end

  test "a passkey can be removed with a fresh passkey re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    passkey = add_passkey(user)

    conn =
      conn
      |> sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{passkey.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(user) == 0
  end

  test "another account's passkey id does nothing", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)
    stranger = user_fixture()
    theirs = add_passkey(stranger)

    conn =
      conn
      |> sign_in(user, :passkey)
      |> post(~p"/settings/security/passkeys/#{theirs.id}/delete")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Passkeys.count_for_user(stranger) == 1
  end

  test "recovery codes are shown once and only once", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> sign_in(user, :passkey) |> post(~p"/settings/security/recovery-codes")

    body = html_response(conn, 200)
    assert body |> shown_codes() |> then(&Regex.scan(@code, &1)) |> length() == 10
    assert RecoveryCodes.remaining(user) == 10

    reloaded = get(recycle(conn), ~p"/settings/security")
    refute reloaded |> html_response(200) |> shown_codes() |> then(&Regex.match?(@code, &1))
  end

  test "an anonymous visitor is sent to the login page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/settings/security")) == ~p"/login"
  end
end
