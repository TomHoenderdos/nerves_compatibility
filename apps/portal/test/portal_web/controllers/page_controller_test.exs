defmodule PortalWeb.PageControllerTest do
  use PortalWeb.ConnCase

  # `add_test_passkey/1`: an admin without one is bounced to
  # `/settings/security` by `PortalWeb.Plugs.RequireAdmin`, so every admin
  # here that means to reach an admin page carries one. The gate itself is
  # covered in `PortalWeb.Plugs.RequireAdminTest`.
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

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

  defp stored_request_names do
    Portal.ScanRequests.ScanRequest
    |> Ash.read!(domain: Portal.ScanRequests)
    |> Enum.map(& &1.package_name)
  end

  test "POST /requests/anonymous refuses names hex.pm does not know, storing nothing", %{
    conn: conn
  } do
    Process.put({:fake_hex_package, "not_on_hex"}, {:ok, false})
    Process.put({:fake_hex_package, "also_missing"}, {:ok, false})

    conn =
      post(conn, ~p"/requests/anonymous", %{
        "packages" => "real_pkg not_on_hex also_missing"
      })

    assert html_response(conn, 200) =~ "Not a Hex package: not_on_hex, also_missing."
    assert stored_request_names() == []
  end

  test "POST /requests/anonymous stores nothing when hex.pm cannot be reached", %{conn: conn} do
    Process.put({:fake_hex_package, "flaky_pkg"}, {:error, :hex_api_unavailable})

    conn = post(conn, ~p"/requests/anonymous", %{"packages" => "real_pkg flaky_pkg"})

    assert html_response(conn, 200) =~
             "Could not reach hex.pm to check the package names. Try again in a moment."

    assert stored_request_names() == []
  end

  test "POST /requests/anonymous refuses more than 25 names before looking any up", %{
    conn: conn
  } do
    names = Enum.map(1..26, &"capped_#{&1}")
    # Were any of them looked up, this answer would refuse the submission with
    # a different message.
    for name <- names, do: Process.put({:fake_hex_package, name}, {:ok, false})

    conn = post(conn, ~p"/requests/anonymous", %{"packages" => Enum.join(names, " ")})

    assert html_response(conn, 200) =~ "Request at most 25 packages at a time."
    assert stored_request_names() == []
  end

  test "POST /requests/anonymous accepts exactly 25 names", %{conn: conn} do
    names = Enum.map(1..25, &"capped_#{&1}")

    conn = post(conn, ~p"/requests/anonymous", %{"packages" => Enum.join(names, " ")})

    assert html_response(conn, 200) =~ "Accepted anonymous 25 requests"
  end

  test "POST /requests/anonymous accepts a name hex.pm knows", %{conn: conn} do
    Process.put({:fake_hex_package, "known_pkg"}, {:ok, true})

    conn = post(conn, ~p"/requests/anonymous", %{"packages" => "known_pkg"})

    assert html_response(conn, 200) =~ "pending human review"
    assert stored_request_names() == ["known_pkg"]
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

    # the package page is where its progress is shown
    assert body =~ ~s(href="/packages/coolpkg")
  end

  test "POST /auth/github/start reports unavailable without a configured GitHub client", %{
    conn: conn
  } do
    conn = post(conn, ~p"/auth/github/start", %{"packages" => "jason"})

    assert html_response(conn, 200) =~ "GitHub login is unavailable"
  end

  # An enrolled admin who signed in with a password does not land on `/admin`,
  # because `RequireAdmin` would refuse that session the moment it arrived --
  # a redirect, a second redirect and an error flash. The passkey landing is
  # pinned in `PortalWeb.PasskeyControllerTest` instead, on the path that can
  # actually reach it.
  test "signing in with a password does not land an enrolled admin on /admin", %{conn: conn} do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("landing_admin", "correct horse battery staple")

    add_test_passkey(admin)

    conn =
      post(conn, ~p"/login", %{
        "username" => admin.username,
        "password" => "correct horse battery staple"
      })

    assert redirected_to(conn) == ~p"/settings/security"
    assert get_session(conn, :login_method) == :password
  end

  test "an admin without a passkey lands on security settings instead", %{conn: conn} do
    # Otherwise every login is a redirect to `/admin`, an immediate second
    # redirect back out and an error flash -- the enrolment prompt reading as
    # a failure, on every login, forever.
    {:ok, _admin} =
      Portal.Accounts.seed_admin_user("landing_unenrolled", "correct horse battery staple")

    conn =
      post(conn, ~p"/login", %{
        "username" => "landing_unenrolled",
        "password" => "correct horse battery staple"
      })

    assert redirected_to(conn) == ~p"/settings/security"
  end

  test "signing in as an ordinary user still lands on the scan request form", %{conn: conn} do
    # The other half of the branch, and the reason it is a separate test: a
    # `landing_path/1` that ignored its argument and always returned `/admin`
    # would satisfy the admin case above while sending every visitor to a page
    # they are not allowed to see.
    {:ok, _user} =
      Portal.Accounts.register_user("landing_plain", "correct horse battery staple")

    conn =
      post(conn, ~p"/login", %{
        "username" => "landing_plain",
        "password" => "correct horse battery staple"
      })

    assert redirected_to(conn) == ~p"/request-scan"
  end

  test "a password login clears a stale pending provider identity", %{conn: conn} do
    # A provider sign-in abandoned at choose-username must not survive a
    # login by another route and later create an account from this session.
    {:ok, user} = Portal.Accounts.register_user("stale_pending", "correct horse battery staple")

    stale = %{
      "provider" => "hex",
      "uid" => "someone-else",
      "username" => "someone-else",
      "profile" => %{},
      "at" => System.system_time(:second)
    }

    conn =
      conn
      |> init_test_session(%{pending_identity: stale})
      |> post(~p"/login", %{
        "username" => "stale_pending",
        "password" => "correct horse battery staple"
      })

    assert get_session(conn, :user_id) == user.id
    refute get_session(conn, :pending_identity)
  end

  test "GET /admin redirects anonymous users", %{conn: conn} do
    conn = get(conn, ~p"/admin")

    assert redirected_to(conn) == ~p"/login"
  end

  test "GET /admin shows queue and anonymous approvals for admins", %{conn: conn} do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("admin_queue", "correct horse battery staple")

    add_test_passkey(admin)

    conn =
      conn
      |> init_test_session(user_id: admin.id, login_method: :passkey)
      |> post(~p"/requests/anonymous", %{"packages" => "admin_anon_review"})

    conn = get(recycle(conn), ~p"/admin/queue")

    assert html_response(conn, 200) =~ "Queue a scan"
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

    add_test_passkey(admin)

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
      |> init_test_session(user_id: admin.id, login_method: :passkey)
      |> post(~p"/admin/requests/#{request.id}/approve")

    assert html_response(conn, 200) =~ "Approved anonymous request for jason"

    assert {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :queued
  end

  defp signed_in_admin(conn, username) do
    {:ok, admin} = Portal.Accounts.seed_admin_user(username, "correct horse battery staple")
    {init_test_session(conn, user_id: add_test_passkey(admin).id, login_method: :passkey), admin}
  end

  # Every one of these routes takes an action on the queue. `RequireAdmin` is
  # the only thing standing between them and the open internet, so each is
  # checked for the gate as well as for the action.
  test "the new admin routes are all closed to anonymous visitors", %{conn: conn} do
    for path <- [
          ~p"/admin/scan",
          ~p"/admin/update-check",
          ~p"/admin/argus",
          ~p"/admin/requests/#{Ecto.UUID.generate()}/priority"
        ] do
      assert redirected_to(post(recycle(conn), path)) == ~p"/login"
    end
  end

  test "POST /admin/scan queues a package at the front of the queue", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_scan")

    conn = post(conn, ~p"/admin/scan", %{"package_name" => "admin_queued_pkg"})

    assert html_response(conn, 200) =~ "Queued admin_queued_pkg"

    request = Portal.ScanRequests.open_request_for_package("admin_queued_pkg")
    assert request.source == :admin_manual
    assert request.status == :queued
  end

  test "POST /admin/scan reports a name that cannot be a package", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_scan_bad")

    conn = post(conn, ~p"/admin/scan", %{"package_name" => "not a package name"})

    assert html_response(conn, 200) =~ "does not look like a hex.pm package name"
    assert Portal.ScanRequests.open_request_for_package("not a package name") == nil
  end

  test "POST /admin/scan says which request is already open", %{conn: conn} do
    {conn, admin} = signed_in_admin(conn, "admin_scan_dup")
    {:ok, _} = Portal.Admin.queue_package("admin_dup_pkg", admin)

    conn = post(conn, ~p"/admin/scan", %{"package_name" => "admin_dup_pkg"})

    assert html_response(conn, 200) =~ "already has an open request"
  end

  test "POST /admin/requests/:id/priority moves the build down the queue", %{conn: conn} do
    {conn, admin} = signed_in_admin(conn, "admin_priority")
    for i <- 1..50, do: Portal.PackageListingFixtures.request_fixture("earlier_#{i}")
    {:ok, request} = Portal.Admin.queue_package("admin_priority_pkg", admin)

    conn =
      post(conn, ~p"/admin/requests/#{request.id}/priority", %{
        "direction" => "down",
        "queue_page" => "2"
      })

    assert html_response(conn, 200) =~ "Moved to priority 1"
    assert Portal.Admin.queue_positions([request.id])[request.id].priority == 1

    doc = conn |> html_response(200) |> LazyHTML.from_document()
    assert [_] = doc |> LazyHTML.query("#queue tbody tr") |> Enum.to_list()
    assert doc |> LazyHTML.query("#queue tbody") |> LazyHTML.text() =~ "admin_priority_pkg"

    assert ["2"] =
             doc
             |> LazyHTML.query("#queue input[name=queue_page]")
             |> LazyHTML.attribute("value")
             |> Enum.uniq()
  end

  test "POST /admin/requests/:id/priority reports a request with no job", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_priority_none")

    conn =
      post(conn, ~p"/admin/requests/#{Ecto.UUID.generate()}/priority", %{"direction" => "up"})

    assert html_response(conn, 200) =~ "nothing to reorder"
  end

  test "POST /admin/update-check queues a run, and says so", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_update_check")

    conn = post(conn, ~p"/admin/update-check", %{})

    assert html_response(conn, 200) =~ "Update check queued"
    assert Portal.Admin.update_check_status().pending?
  end

  test "POST /admin/update-check with mode=dry_run queues nothing but a report", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_update_dry")

    conn = post(conn, ~p"/admin/update-check", %{"mode" => "dry_run"})

    assert html_response(conn, 200) =~ "queues nothing"
  end

  test "the queue and maintenance sections carry the scan form and the update check",
       %{conn: conn} do
    {conn, admin} = signed_in_admin(conn, "admin_panels")
    # The queue table, and so its position column, only renders with a row in
    # it -- an empty queue shows the empty state instead.
    {:ok, _} = Portal.Admin.queue_package("admin_panel_pkg", admin)

    queue = html_response(get(conn, ~p"/admin/queue"), 200)
    assert queue =~ ~s(action="/admin/scan")
    assert queue =~ "Queue position"

    maintenance = html_response(get(conn, ~p"/admin/maintenance"), 200)
    assert maintenance =~ ~s(action="/admin/update-check")
    assert maintenance =~ "hex.pm update check"
  end

  test "POST /admin/argus saves the settings and shows them", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_argus")

    conn =
      post(conn, ~p"/admin/argus", %{
        "argus" => %{
          "enabled" => "true",
          "analyses" => ["default", "unsafe_input"],
          "scope" => "all",
          "min_severity" => "error",
          "timeout_seconds" => "600"
        }
      })

    html = html_response(conn, 200)
    assert html =~ "Static analysis (argus)"
    assert html =~ "Saved argus settings."
    assert Portal.Settings.get().argus_analyses == [:default, :unsafe_input]
  end

  test "POST /admin/argus with no analyses flashes an error", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_argus_bad")

    conn =
      post(conn, ~p"/admin/argus", %{
        "argus" => %{
          "enabled" => "true",
          "scope" => "firmware",
          "min_severity" => "warning",
          "timeout_seconds" => "300"
        }
      })

    assert html_response(conn, 200) =~ "Tick at least one analysis"
  end
end
