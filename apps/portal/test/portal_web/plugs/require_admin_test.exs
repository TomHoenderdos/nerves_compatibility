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

  # Derived from the router, never written out. These seven are gated by an
  # in-action `case require_admin(conn)` convention rather than by a pipeline,
  # so nothing structural forces an eighth admin action to be gated. A literal
  # list here would miss that route twice over: it would ship ungated, and the
  # sweep built to catch exactly that would not look at it.
  defp guarded_routes do
    id = Ecto.UUID.generate()

    PortalWeb.Router.__routes__()
    |> Enum.filter(&(&1.path == "/admin" or String.starts_with?(&1.path, "/admin/")))
    # `/admin/oban` is the one deliberate exception, and it is short and
    # stable: the dashboard LiveView needs `Oban.Met`, which `Oban, testing:
    # :manual` does not start, so it can only be exercised on the refusal path
    # where the gate answers before the mount. Covered separately, both on
    # that path and at `on_mount/4`.
    |> Enum.reject(&String.starts_with?(&1.path, "/admin/oban"))
    |> Enum.map(&{&1.verb, String.replace(&1.path, ":id", id)})
  end

  # A fresh conn per route. `recycle/1` carries the session only through a conn
  # that has already been dispatched — `Plug.Session` writes it into
  # `resp_cookies` on the way out. Recycling the not-yet-sent signed-in conn
  # finds no cookie, so every sweep below would silently run as an anonymous
  # redirect to `/login`.
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

  # Without this, a `guarded_routes/0` that derived nothing — a router filter
  # that stopped matching, a rename — would make all three sweeps below pass
  # over an empty list and assert nothing at all.
  test "the derived route list really is the admin surface" do
    routes = guarded_routes()

    assert length(routes) >= 7
    assert {:get, "/admin"} in routes
    assert Enum.all?(routes, fn {_verb, path} -> String.starts_with?(path, "/admin") end)
    refute Enum.any?(routes, fn {_verb, path} -> String.contains?(path, "oban") end)
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
    admin = admin_with_passkey_fixture()

    for {verb, path} <- guarded_routes() do
      conn = request(admin, verb, path)

      assert conn.status == 200, "#{verb} #{path} refused an enrolled admin"
    end
  end

  test "an admin action is closed to a non-admin without a passkey nag" do
    user = user_fixture()

    for {verb, path} <- guarded_routes() do
      conn = request(user, verb, path)

      assert redirected_to(conn) == ~p"/request-scan",
             "#{verb} #{path} sent a non-admin somewhere other than the scan form"

      refute Phoenix.Flash.get(conn.assigns.flash, :error) =~ "passkey",
             "#{verb} #{path} nagged a non-admin about passkeys"
    end
  end

  # `on_mount/4`: the same decision on the path a router pipeline never sees.
  # A pipeline runs on the initial HTTP request only; a LiveView reconnect is
  # authenticated by the signed session token from that dead render, so
  # without this hook an admin who had `/admin/oban` open before the passkey
  # requirement shipped keeps reconnecting to it for the token's 14-day life.
  # Driven directly rather than through `live/2`, because the dead render that
  # `live/2` performs is refused by the `:admin` pipeline first and would
  # prove the pipeline rather than the hook.
  defp mount(user_id) do
    session = if user_id, do: %{"user_id" => user_id}, else: %{}

    # LiveView populates `:flash` before it runs `on_mount` hooks, which is why
    # a hook may `put_flash/3`; a bare `%Socket{}` has not been through that,
    # so the assign is seeded here rather than the hook learning to cope
    # without it.
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

    PortalWeb.Plugs.RequireAdmin.on_mount(:require_admin_passkey, %{}, session, socket)
  end

  test "a passkey-less admin cannot mount the dashboard, only fail to GET it" do
    admin = admin_fixture()

    assert {:halt, socket} = mount(admin.id)
    assert socket.redirected == {:redirect, %{to: ~p"/settings/security", status: 302}}
    assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "passkey"
  end

  test "an admin with a passkey mounts the dashboard" do
    admin = admin_with_passkey_fixture()

    assert {:cont, socket} = mount(admin.id)
    refute socket.redirected
  end

  test "a non-admin mount is sent away without a passkey nag" do
    user = user_fixture()

    assert {:halt, socket} = mount(user.id)
    assert socket.redirected == {:redirect, %{to: ~p"/request-scan", status: 302}}
    refute Phoenix.Flash.get(socket.assigns.flash, :error) =~ "passkey"
  end

  test "an anonymous mount is sent to the login page" do
    assert {:halt, socket} = mount(nil)
    assert socket.redirected == {:redirect, %{to: ~p"/login", status: 302}}
  end
end
