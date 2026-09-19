defmodule PortalWeb.Plugs.RequireAdminTest do
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Passkeys

  defp add_passkey(user) do
    {:ok, _} =
      Passkeys.create(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(%{3 => -7}),
        nickname: "laptop"
      })

    :ok
  end

  defp sign_in(conn, user) do
    conn |> init_test_session(%{}) |> put_session(:user_id, user.id)
  end

  # Every route the admin policy guards, minus `/admin/oban`: the dashboard
  # LiveView needs `Oban.Met`, which `Oban, testing: :manual` does not start,
  # so it can only be checked on the refusal path where the gate answers
  # before the mount. The `POST`s all take an action on the build queue —
  # approving a scan request, reordering it, starting an update check — which
  # is why each one is swept here rather than trusting `/admin` to stand in
  # for the set.
  defp guarded_routes do
    id = Ecto.UUID.generate()

    [
      {:get, ~p"/admin"},
      {:get, ~p"/admin/monitor"},
      {:post, ~p"/admin/scan"},
      {:post, ~p"/admin/update-check"},
      {:post, ~p"/admin/requests/#{id}/approve"},
      {:post, ~p"/admin/requests/#{id}/reject"},
      {:post, ~p"/admin/requests/#{id}/priority"}
    ]
  end

  # A fresh conn per route: `init_test_session/2` writes the session on the
  # conn rather than into a cookie, so `recycle/1` would drop it and every
  # sweep below would pass as an anonymous redirect to `/login`.
  defp request(user, :get, path), do: build_conn() |> sign_in(user) |> get(path)
  defp request(user, :post, path), do: build_conn() |> sign_in(user) |> post(path, %{})

  test "an admin with a passkey reaches the admin page", %{conn: conn} do
    admin = admin_fixture()
    add_passkey(admin)

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert html_response(conn, 200)
  end

  test "an admin without a passkey is sent to security settings", %{conn: conn} do
    admin = admin_fixture()

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/settings/security"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey"
  end

  test "TOTP alone does not open the admin page", %{conn: conn} do
    admin = admin_fixture()
    {:ok, %{secret: secret}} = Portal.Accounts.Totp.start_enrolment(admin)
    :ok = Portal.Accounts.Totp.confirm(admin, NimbleTOTP.verification_code(secret))

    conn = conn |> sign_in(admin) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/settings/security"
  end

  test "a non-admin is still sent away without a passkey nag", %{conn: conn} do
    user = user_fixture()

    conn = conn |> sign_in(user) |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/request-scan"
    refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey"
  end

  test "an anonymous visitor goes to the login page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/admin")) == ~p"/login"
  end

  test "the oban dashboard is gated the same way", %{conn: conn} do
    admin = admin_fixture()

    conn = conn |> sign_in(admin) |> get("/admin/oban")

    assert redirected_to(conn) == ~p"/settings/security"
  end

  # The dashboard is not the prize. `/admin` and the queue endpoints below are
  # gated by `PageController.require_admin/1`, a separate call site into the
  # same policy, so each one is checked directly rather than inferred from the
  # `/admin/oban` case above.
  test "no admin action opens for an admin without a passkey" do
    admin = admin_fixture()

    for {verb, path} <- guarded_routes() do
      conn = request(admin, verb, path)

      assert redirected_to(conn) == ~p"/settings/security",
             "#{verb} #{path} let a passkey-less admin through"
    end
  end

  test "every admin action opens once the admin holds a passkey" do
    admin = admin_fixture()
    add_passkey(admin)

    for {verb, path} <- guarded_routes() do
      conn = request(admin, verb, path)

      assert conn.status == 200, "#{verb} #{path} refused an enrolled admin"
    end
  end

  test "an admin action is closed to a non-admin without a passkey nag" do
    user = user_fixture()

    for {verb, path} <- guarded_routes() do
      conn = request(user, verb, path)

      assert redirected_to(conn) == ~p"/request-scan"
      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey"
    end
  end
end
