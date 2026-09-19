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

  # A code for the controller to check against *its* clock. `SecurityController`
  # calls the two-arity `Totp.verify/2` and `Totp.confirm/2`, which read
  # `DateTime.utc_now()` themselves, so a code minted in the last moment of a
  # 30-second step is checked against the next one and fails. Wait the step out
  # rather than thread an injectable clock through an HTTP-facing controller.
  defp live_totp_code(secret) do
    case 30 - rem(System.system_time(:second), 30) do
      left when left <= 2 -> Process.sleep(left * 1000)
      _ -> :ok
    end

    NimbleTOTP.verification_code(secret)
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

  defp reloaded_body(conn) do
    conn |> recycle([]) |> get(~p"/settings/security") |> html_response(200)
  end

  test "the page lists factors and is reachable without a fresh re-auth", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> stale_sign_in(user) |> get(~p"/settings/security")

    body = html_response(conn, 200)
    assert body =~ "laptop"
    assert body =~ "Security"
  end

  test "an unsatisfied admin is told why an authenticator app will not do", %{conn: conn} do
    admin = admin_fixture(%{password: @password})
    add_totp(admin)

    body =
      conn |> stale_sign_in(admin, :totp) |> get(~p"/settings/security") |> html_response(200)

    # The only place a human ever meets the passkeys-only-for-admin rule. Without
    # the reason it reads as an arbitrary requirement, and the predictable next
    # move is someone "fixing" `Mfa.admin_satisfied?/1` to accept TOTP.
    assert body =~ "Admin accounts need a passkey to reach"
    assert body =~ "An authenticator app does not substitute:"
    assert body =~ "a passkey cannot be phished, and a code can."
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

    assert html_response(conn, 200) =~ "Your password no longer authorises changes here."
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
        "credential" => live_totp_code(secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :reauth_method) == :totp
  end

  test "a locked-out authenticator says so instead of blaming the typing", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_totp(user)

    wrong_code = fn conn ->
      post(conn, ~p"/settings/security/reauth", %{"method" => "totp", "credential" => "000000"})
    end

    # Five wrong codes is the lockout threshold, and the fifth is the attempt
    # that reports it. `recycle/1` carries the session cookie between posts; the
    # first conn has no response to recycle yet.
    conn = conn |> sign_in(user, :totp) |> wrong_code.()
    conn = Enum.reduce(2..5, conn, fn _i, conn -> conn |> recycle() |> wrong_code.() end)

    body = html_response(conn, 200)
    assert body =~ "Too many wrong codes."
    refute body =~ "That did not match."
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

  # The break-glass loop. After `Recovery.clear_factors!/1` the admin holds no
  # factor, so they sign in with the password alone -- a session `RequireAdmin`
  # refuses. Registration is a `user_verification: "required"` possession
  # ceremony, so it upgrades the session in place; without that the admin is
  # stuck at `/settings/security` until they sign out and back in.
  test "registering a passkey upgrades the session's login method", %{conn: conn} do
    admin = admin_fixture(%{password: @password})
    authenticator = SoftwareAuthenticator.new(@rp_id)

    conn =
      conn
      |> sign_in(admin)
      |> put_session(:login_method, :password)
      |> asks_for_json()
      |> post(~p"/settings/security/passkeys/challenge")

    challenge = stashed_challenge(conn)
    response = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    conn =
      post(recycle(conn), ~p"/settings/security/passkeys", %{
        "nickname" => "yubikey",
        "attestation_object" => WebAuthn.b64(response.attestation_object),
        "client_data_json" => WebAuthn.b64(response.client_data_json),
        "transports" => ["usb"]
      })

    assert json_response(conn, 200)["ok"]
    assert get_session(conn, :login_method) == :passkey

    # And the gate agrees, on the same session. The `accept` header is dropped
    # because `recycle/1` carries the JSON one forward and `/admin` is HTML.
    admin_conn = conn |> recycle() |> delete_req_header("accept") |> get(~p"/admin")

    assert admin_conn.status == 200
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

  # The spec, the plan and `Totp.start_enrolment/1`'s own docstring all ask for
  # a QR code plus a manual key. A raw `otpauth://` URI printed as text is
  # neither: no authenticator can scan a string, and none accepts a whole URI
  # in its manual-entry field -- that wants the bare base32 secret, which the
  # URI buries in a query parameter.
  test "TOTP enrolment renders a scannable QR code and a manual key", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")
    body = html_response(conn, 200)

    {:ok, stored} = Totp.get_secret(user)

    # Matched textually rather than through `LazyHTML`: lexbor parses this as a
    # fragment in HTML context, where `<svg>` is foreign content -- every
    # `svg`/`rect` selector answers zero on markup that is plainly there, and
    # the mis-nesting swallows the siblings that follow it too.
    assert body =~ ~s(id="totp-qr")
    assert body =~ "<svg "
    assert body =~ "<rect "

    # The manual key is the bare base32 secret -- what an authenticator's
    # manual-entry field accepts -- and not the URI, which buries it in a
    # query parameter.
    assert body =~ ~s(id="totp-manual-key")
    assert body =~ PortalWeb.SecurityHTML.totp_manual_key(stored.secret)

    assert PortalWeb.SecurityHTML.totp_manual_key(stored.secret) |> String.replace(" ", "") ==
             Base.encode32(stored.secret, padding: false)

    # And the URI is no longer dumped as text where the key used to hide.
    refute body =~ "otpauth://totp/"
  end

  test "TOTP enrolment needs one working code before it counts", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")
    body = html_response(conn, 200)

    refute Totp.confirmed?(user)

    {:ok, stored} = Totp.get_secret(user)

    assert body =~ ~s(id="totp-qr")
    assert body =~ PortalWeb.SecurityHTML.totp_manual_key(stored.secret)

    # A typo must not cost the secret: the enrolment comes back with the error,
    # so the code field, the QR code the user already scanned and the manual
    # key are all still there.
    retry = post(recycle(conn), ~p"/settings/security/totp/confirm", %{"code" => "000000"})
    retry_body = html_response(retry, 200)
    assert retry_body =~ ~s(id="totp-qr")
    assert retry_body =~ PortalWeb.SecurityHTML.totp_manual_key(stored.secret)
    assert retry_body =~ "That code did not match."
    assert {:ok, ^stored} = Totp.get_secret(user)

    conn =
      post(recycle(conn), ~p"/settings/security/totp/confirm", %{
        "code" => live_totp_code(stored.secret)
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert Totp.confirmed?(user)

    # The window that authorised this enrolment was opened with the password,
    # which stops being accepted the moment a factor lands. Confirming the
    # factor is proof of the factor, so the recovery codes stay reachable.
    conn = post(recycle(conn), ~p"/settings/security/recovery-codes")

    assert conn |> html_response(200) |> shown_codes() |> then(&Regex.scan(@code, &1)) |> length() ==
             10
  end

  test "a first passkey opens the window that mints the first recovery codes", %{conn: conn} do
    user = user_fixture(%{password: @password})
    authenticator = SoftwareAuthenticator.new(@rp_id)

    # Bootstrap: no factors at all, so the password is the only credential that
    # can open the window.
    conn =
      conn
      |> stale_sign_in(user)
      |> post(~p"/settings/security/reauth", %{"method" => "password", "credential" => @password})

    assert redirected_to(conn) == ~p"/settings/security"

    conn =
      conn
      |> recycle([])
      |> asks_for_json()
      |> post(~p"/settings/security/passkeys/challenge")

    challenge = stashed_challenge(conn)
    created = SoftwareAuthenticator.create(authenticator, challenge.bytes, @origin)

    conn =
      post(recycle(conn), ~p"/settings/security/passkeys", %{
        "nickname" => "laptop",
        "attestation_object" => WebAuthn.b64(created.attestation_object),
        "client_data_json" => WebAuthn.b64(created.client_data_json),
        "transports" => []
      })

    assert json_response(conn, 200)["ok"]

    # `recycle([])` drops the JSON Accept header the four fetch routes need;
    # carrying it into this GET would 406 in the browser pipeline. This is the
    # `window.location.reload()` the JS does after registering.
    reloaded = get(recycle(conn, []), ~p"/settings/security")
    body = html_response(reloaded, 200)

    assert body =~ "You have no recovery codes"
    assert body =~ ~p"/settings/security/recovery-codes"

    conn = post(recycle(reloaded), ~p"/settings/security/recovery-codes")

    assert conn |> html_response(200) |> shown_codes() |> then(&Regex.scan(@code, &1)) |> length() ==
             10

    assert RecoveryCodes.remaining(user) == 10
  end

  test "starting TOTP enrolment again does not destroy a confirmed one", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_totp(user)

    conn = conn |> sign_in(user, :totp) |> post(~p"/settings/security/totp/start")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Remove the current authenticator app"
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
    codes = body |> shown_codes() |> then(&Regex.scan(@code, &1)) |> List.flatten()
    assert length(codes) == 10
    assert RecoveryCodes.remaining(user) == 10

    # Against the whole page, not the one list that renders them: `#new-recovery-codes`
    # does not exist without the assign, so scoping the refute there would ask
    # whether an absent element contains codes and answer "no" unconditionally.
    reloaded = reloaded_body(conn)
    assert reloaded =~ "10 unused codes"
    for code <- codes, do: refute(reloaded =~ code)
  end

  test "an anonymous visitor is sent to the login page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/settings/security")) == ~p"/login"
  end

  # "Exactly one rendered response" is a claim about the server. Without a
  # cache directive the response carrying ten plaintext recovery codes sits in
  # the browser's disk cache and comes back with the back button, which is
  # where the threat model's shared machine lives.
  # `put_secure_browser_headers/2` sets no `Cache-Control` of its own.
  test "the response carrying plaintext recovery codes is not storable", %{conn: conn} do
    user = user_fixture(%{password: @password})
    add_passkey(user)

    conn = conn |> sign_in(user, :passkey) |> post(~p"/settings/security/recovery-codes")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  test "the response carrying the TOTP seed is not storable", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  # An enrolled admin who signs in with a password is redirected here by
  # `landing_path/2`, and the "you need a passkey" banner above does not fire
  # for them -- they have one. Without a second banner they arrive with no
  # explanation at all.
  test "an enrolled admin on a password session is told to sign in with the passkey", %{
    conn: conn
  } do
    admin = admin_fixture(%{password: @password})
    add_passkey(admin)

    conn =
      conn
      |> sign_in(admin)
      |> put_session(:login_method, :password)
      |> get(~p"/settings/security")

    body = html_response(conn, 200)
    assert body =~ "needs a session you opened with your passkey"

    # And it is gone once the session was opened with one.
    passkey_body =
      conn
      |> recycle()
      |> init_test_session(%{})
      |> put_session(:user_id, admin.id)
      |> put_session(:login_method, :passkey)
      |> get(~p"/settings/security")
      |> html_response(200)

    refute passkey_body =~ "needs a session you opened with your passkey"
  end

  # `reauth/2` next door has a fallback clause and
  # `MfaController.totp_verify/2` reads the param with a default. This matched
  # `%{"code" => code}` alone, so a POST without it raised
  # `Phoenix.ActionClauseError` -- a 500 where the page should say the code
  # did not match.
  test "confirming TOTP without a code renders the error instead of raising", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> post(~p"/settings/security/totp/start")

    retry = post(recycle(conn), ~p"/settings/security/totp/confirm", %{})

    assert html_response(retry, 200) =~ "That code did not match."
    refute Totp.confirmed?(user)
  end

  test "the security page itself is not storable", %{conn: conn} do
    user = user_fixture(%{password: @password})

    conn = conn |> sign_in(user) |> get(~p"/settings/security")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
