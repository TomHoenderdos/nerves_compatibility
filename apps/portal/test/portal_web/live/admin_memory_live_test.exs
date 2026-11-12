defmodule PortalWeb.Admin.MemoryLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  import Portal.Test.RunMemoryFixtures

  @pw "correct horse battery staple"
  @gib 1024 * 1024 * 1024

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("memory_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#memory-rows tr[id]")
    |> LazyHTML.attribute("id")
  end

  test "lists each package's peaks, with the warm summary and the explanation", %{conn: conn} do
    seed_run_memory!()
    {:ok, view, html} = live(conn, ~p"/admin/memory")

    assert has_element?(view, ~s(#admin-tabs a[aria-current="page"][href="/admin/memory"]))

    assert rows(view) == [
             "memory-exla-firmware",
             "memory-jason-firmware",
             "memory-jason-toolchain"
           ]

    jason = view |> element("#memory-jason-firmware") |> render()
    assert jason =~ ~s(href="/packages/jason")
    assert jason =~ "2 GiB"
    assert jason =~ "1.9 GiB"
    assert jason =~ "3 GiB"

    assert view |> element("#memory-jason-toolchain") |> render() =~ "600 MiB"
    assert view |> element("#memory-exla-firmware .text-error") |> render() =~ "1"
    refute has_element?(view, "#memory-jason-firmware .text-error")

    assert view |> element("#memory-warm") |> render() =~ "warm runs: 2, max peak 700 MiB"
    assert html =~ "sampled every 5 s from inside the container"
  end

  test "?kind= narrows and ?sort=oom puts the OOM-killed package first", %{conn: conn} do
    seed_run_memory!()
    insert_run_memory!(%{package: "aaa", peak_used_bytes: 10 * @gib, finished_at: days_ago(1)})

    {:ok, view, _html} = live(conn, ~p"/admin/memory?kind=toolchain")
    assert rows(view) == ["memory-jason-toolchain"]

    {:ok, view, _html} = live(conn, ~p"/admin/memory?sort=oom")
    assert [first | _] = rows(view)
    assert first == "memory-exla-firmware"

    {:ok, view, _html} = live(conn, ~p"/admin/memory")
    assert [first | _] = rows(view)
    assert first == "memory-aaa-firmware"

    # The links carry the other parameter, so a view is shareable.
    view |> element("#memory-kind-firmware") |> render_click()
    assert_patch(view, ~p"/admin/memory?kind=firmware&sort=peak")
    view |> element("#memory-sort-oom") |> render_click()
    assert_patch(view, ~p"/admin/memory?kind=firmware&sort=oom")
    assert rows(view) == ["memory-exla-firmware", "memory-aaa-firmware", "memory-jason-firmware"]
  end

  test "unknown parameters fall back to the defaults", %{conn: conn} do
    seed_run_memory!()
    {:ok, view, _html} = live(conn, ~p"/admin/memory?kind=nope&sort=drop_table")
    assert length(rows(view)) == 3
  end

  test "no rows reads as such", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/memory")
    assert render(view) =~ "No container runs in the last 30 days."
    assert view |> element("#memory-warm") |> render() =~ "warm runs: 0"
  end

  test "a password-only admin and a non-admin are refused", %{admin: admin} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/memory")

    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
    assert {:error, {:redirect, %{to: "/settings/security"}}} = live(conn, ~p"/admin/memory")

    {:ok, user} = Portal.Accounts.register_user("plain_memory", @pw)
    conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
    assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/memory")
  end
end
