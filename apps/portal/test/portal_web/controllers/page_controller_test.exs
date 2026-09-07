defmodule PortalWeb.PageControllerTest do
  use PortalWeb.ConnCase

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)
    :ok
  end

  test "GET /request-scan", %{conn: conn} do
    conn = get(conn, ~p"/request-scan")
    assert html_response(conn, 200) =~ "Request scans for packages"
    assert html_response(conn, 200) =~ "Verify with Hex.pm"
    assert html_response(conn, 200) =~ "Verify with GitHub"
    assert html_response(conn, 200) =~ "Request manual review"
    assert html_response(conn, 200) =~ "data-package-picker"
  end

  test "logged-out nav puts auth links in the account dropdown", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)

    assert html =~ ~s(class="site-auth-menu")
    assert html =~ ~s(aria-label="Account menu")
    assert html =~ ~s(class="site-auth-menu-item" href="/login")
    assert html =~ ~s(class="site-auth-menu-item" href="/register")
    refute html =~ ~s(class="nav-link" href="/login">Login)
    refute html =~ ~s(class="nav-link" href="/register">Register)
  end

  test "POST /requests/anonymous creates a pending manual-review request", %{conn: conn} do
    conn = post(conn, ~p"/requests/anonymous", %{"package" => "anon_one"})

    assert html_response(conn, 200) =~ "pending human review"

    requests =
      Portal.ScanRequests.ScanRequest
      |> Ash.read!(domain: Portal.ScanRequests)

    assert Enum.any?(
             requests,
             &(&1.package_name == "anon_one" and &1.source == :anonymous_manual and
                 &1.status == :pending)
           )
  end

  test "POST /requests/anonymous accepts multiple package names", %{conn: conn} do
    conn = post(conn, ~p"/requests/anonymous", %{"packages" => "anon_two\nanon_three, anon_four"})

    assert html_response(conn, 200) =~ "Accepted anonymous 3 requests"

    package_names =
      Portal.ScanRequests.ScanRequest
      |> Ash.read!(domain: Portal.ScanRequests)
      |> Enum.map(& &1.package_name)

    assert "anon_two" in package_names
    assert "anon_three" in package_names
    assert "anon_four" in package_names
  end

  test "POST /requests/anonymous deduplicates open package requests", %{conn: conn} do
    _conn = post(conn, ~p"/requests/anonymous", %{"packages" => "anon_dedupe anon_dedupe"})
    _conn = post(conn, ~p"/requests/anonymous", %{"packages" => "anon_dedupe"})

    requests =
      Portal.ScanRequests.ScanRequest
      |> Ash.read!(domain: Portal.ScanRequests)
      |> Enum.filter(&(&1.package_name == "anon_dedupe" and &1.status == :pending))

    assert length(requests) == 1
  end

  test "submitting an anonymous request shows a confirmation panel linking to each request", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/requests/anonymous", %{
        "packages" => "coolpkg",
        "verification_method" => "anonymous"
      })

    body = html_response(conn, 200)
    assert body =~ "track progress"
    assert body =~ "coolpkg"

    # a /requests/<uuid> link is present
    assert body =~ ~r/\/requests\/[0-9a-f-]{36}/
  end

  test "POST /auth/github/start reports unavailable without a configured GitHub client", %{
    conn: conn
  } do
    conn = post(conn, ~p"/auth/github/start", %{"packages" => "jason"})

    assert html_response(conn, 200) =~ "GitHub login is unavailable"
  end

  test "GET /admin redirects anonymous users", %{conn: conn} do
    conn = get(conn, ~p"/admin")

    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /admin shows queue and anonymous approvals for admins", %{conn: conn} do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("admin_queue", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: admin.id)
      |> post(~p"/requests/anonymous", %{"packages" => "admin_anon_review"})

    conn = get(recycle(conn), ~p"/admin")

    assert html_response(conn, 200) =~ "Scan request operations"
    assert html_response(conn, 200) =~ "Anonymous approvals"
    assert html_response(conn, 200) =~ "admin_anon_review"
    assert html_response(conn, 200) =~ "Approve"
  end

  test "GET /settings redirects anonymous users", %{conn: conn} do
    conn = get(conn, ~p"/settings")

    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /settings shows the current username for signed-in users", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_viewer", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> get(~p"/settings")

    body = html_response(conn, 200)
    assert body =~ "Account settings"
    assert body =~ "Change username"
    assert body =~ "Change password"
    assert body =~ "settings_viewer"
  end

  test "POST /settings updates the username", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_rename", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{"username" => "settings_renamed"})

    assert html_response(conn, 200) =~ "Account settings updated."

    assert {:ok, updated} = Portal.Accounts.get_user(user.id)
    assert updated.username == "settings_renamed"
  end

  test "POST /settings rejects a username taken by another user", %{conn: conn} do
    {:ok, other} = Portal.Accounts.register_user("settings_taken", "correct horse battery staple")
    {:ok, user} = Portal.Accounts.register_user("settings_thief", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{"username" => other.username})

    assert html_response(conn, 200) =~ "That username is already registered."

    assert {:ok, unchanged} = Portal.Accounts.get_user(user.id)
    assert unchanged.username == "settings_thief"
  end

  test "POST /settings rejects an invalid username", %{conn: conn} do
    {:ok, user} =
      Portal.Accounts.register_user("settings_invalid", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{"username" => "no"})

    assert html_response(conn, 200) =~ "Use a username with 3-40 letters"

    assert {:ok, unchanged} = Portal.Accounts.get_user(user.id)
    assert unchanged.username == "settings_invalid"
  end

  test "POST /settings keeping the same username succeeds", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_same", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{"username" => "settings_same"})

    assert html_response(conn, 200) =~ "Account settings updated."

    assert {:ok, updated} = Portal.Accounts.get_user(user.id)
    assert updated.username == "settings_same"
  end

  test "POST /settings changes the password with the correct current password", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_pwd", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{
        "current_password" => "correct horse battery staple",
        "new_password" => "another much longer secret"
      })

    assert html_response(conn, 200) =~ "Account settings updated."

    assert {:ok, updated} = Portal.Accounts.get_user(user.id)
    refute Argon2.verify_pass("correct horse battery staple", updated.password_hash)
    assert Argon2.verify_pass("another much longer secret", updated.password_hash)
  end

  test "POST /settings rejects a wrong current password", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_badpwd", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{
        "current_password" => "wrong horse battery staple",
        "new_password" => "another much longer secret"
      })

    assert html_response(conn, 200) =~ "Current password is incorrect."

    assert {:ok, unchanged} = Portal.Accounts.get_user(user.id)
    assert Argon2.verify_pass("correct horse battery staple", unchanged.password_hash)
    refute Argon2.verify_pass("another much longer secret", unchanged.password_hash)
  end

  test "POST /settings rejects a too-short new password", %{conn: conn} do
    {:ok, user} =
      Portal.Accounts.register_user("settings_shortpwd", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> post(~p"/settings", %{
        "current_password" => "correct horse battery staple",
        "new_password" => "short"
      })

    assert html_response(conn, 200) =~ "New password must be at least 12 characters."

    assert {:ok, unchanged} = Portal.Accounts.get_user(user.id)
    assert Argon2.verify_pass("correct horse battery staple", unchanged.password_hash)
  end

  test "signed-in nav links to the settings page", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("settings_nav", "correct horse battery staple")

    conn =
      conn
      |> init_test_session(user_id: user.id)
      |> get(~p"/settings")

    assert html_response(conn, 200) =~ ~s(href="/settings">Settings)
  end

  test "POST /admin/requests/:id/approve accepts pending anonymous request", %{conn: conn} do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("admin_review", "correct horse battery staple")

    request =
      Portal.ScanRequests.ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: "jason",
        source: :anonymous_manual,
        status: :pending,
        subject: "anonymous",
        verification_provider: "manual_review"
      })
      |> Ash.create!(domain: Portal.ScanRequests)

    conn =
      conn
      |> init_test_session(user_id: admin.id)
      |> post(~p"/admin/requests/#{request.id}/approve")

    assert html_response(conn, 200) =~ "Approved anonymous request for jason"

    assert {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :queued
  end
end
