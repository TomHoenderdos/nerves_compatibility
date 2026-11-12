defmodule PortalWeb.Admin.NotPrecompiledLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]
  import Portal.Test.NotPrecompiledFixtures

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("np_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp listed(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#np-rows tr[id] td:first-child a")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  test "renders the causes, blockers, env vars and packages for an admin", %{conn: conn} do
    seed_not_precompiled!()
    {:ok, view, html} = live(conn, ~p"/admin/not-precompiled")

    assert has_element?(
             view,
             ~s(#admin-tabs a[aria-current="page"][href="/admin/not-precompiled"])
           )

    assert html =~ "Not precompiled"

    assert view |> element("#np-class-build_hooks") |> render() =~ "1,410"
    assert view |> element("#np-class-env_read") |> render() =~ "300"
    refute has_element?(view, "#np-class-no_beams")

    blocker = view |> element("#np-blocker-hackney") |> render()
    assert blocker =~ "req_like, tesla_like, small_hackney"
    assert view |> element("#np-env-GITHUB_ACTIONS") |> render() =~ "1"

    assert listed(view) == ["req_like", "tesla_like", "env_reader", "small_hackney"]
    row = view |> element("#np-row-req_like-0") |> render()
    assert row =~ ~s(href="/packages/req_like")
    assert row =~ "1.19/28, 1.20/29"
    assert row =~ "via hackney"
    assert row =~ "rebar3 build runs post_hooks"
  end

  test "the filters narrow the list and land in the URL", %{conn: conn} do
    seed_not_precompiled!()
    {:ok, view, _html} = live(conn, ~p"/admin/not-precompiled")

    view |> element("#np-blocker-hackney a") |> render_click()
    assert_patch(view, ~p"/admin/not-precompiled?blocker=hackney")
    assert listed(view) == ["req_like", "tesla_like", "small_hackney"]

    view |> element("#np-env-GITHUB_ACTIONS a") |> render_click()
    assert_patch(view, ~p"/admin/not-precompiled?class=env_read&detail=GITHUB_ACTIONS")
    assert listed(view) == ["env_reader"]

    view
    |> form("#np-filter", f: %{class: "build_hooks", detail: "", blocker: ""})
    |> render_change()

    assert_patch(view, ~p"/admin/not-precompiled?class=build_hooks")
    assert listed(view) == ["req_like", "tesla_like", "small_hackney"]

    view |> element("#np-clear") |> render_click()
    assert_patch(view, ~p"/admin/not-precompiled")
    assert length(listed(view)) == 4
  end

  test "an unknown class is ignored and an unmatched filter reads as such", %{conn: conn} do
    seed_not_precompiled!()
    {:ok, view, _html} = live(conn, ~p"/admin/not-precompiled?class=drop_table")
    assert length(listed(view)) == 4

    {:ok, view, _html} = live(conn, ~p"/admin/not-precompiled?blocker=nobody")
    assert render(view) =~ "No packages match."
  end

  test "no skipped builds", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/not-precompiled")
    assert html =~ "No skipped builds."
  end

  test "a password-only admin and a non-admin are refused", %{admin: admin} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/not-precompiled")

    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)

    assert {:error, {:redirect, %{to: "/settings/security"}}} =
             live(conn, ~p"/admin/not-precompiled")

    {:ok, user} = Portal.Accounts.register_user("plain_np", @pw)
    conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
    assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/not-precompiled")
  end
end
