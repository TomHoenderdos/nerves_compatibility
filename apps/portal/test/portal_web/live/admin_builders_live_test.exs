defmodule PortalWeb.Admin.BuildersLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  alias Portal.Builders
  alias Portal.Builders.{CA, Lease, Leases}

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    {:ok, admin} = Portal.Accounts.seed_admin_user("builders_admin", @pw)
    admin = add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey)}
  end

  defp enrol!(name) do
    {:ok, %{token: token}} = Builders.create_token(name, "test")
    csr = X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()
    {:ok, %{builder: builder}} = Builders.enrol(token, csr, %{})
    builder
  end

  defp enqueue! do
    {:ok, _} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.4",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: nil,
        priority: 5
      })
  end

  test "lists builders and leases and mints a token shown once", %{conn: conn} do
    builder = enrol!("box-ui")
    enqueue!()
    {:ok, view, _html} = live(conn, ~p"/admin/builders")
    assert has_element?(view, "#builders #builder-#{builder.id}")
    assert has_element?(view, "#leases", "jason")
    assert has_element?(view, "#remote-settings")

    view |> form("#new-token-form", %{"name" => "box-new"}) |> render_submit()
    assert has_element?(view, "#enrolment-token")

    token =
      view
      |> element("#enrolment-token")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert [_, _, _] = String.split(token, ".")
  end

  test "toggles publishing, revokes, requeues and saves the routing policy", %{conn: conn} do
    builder = enrol!("box-act")
    enqueue!()
    {:ok, lease} = Leases.claim(builder)
    {:ok, :rejected, lease} = Leases.complete(lease, 11)

    {:ok, view, _} = live(conn, ~p"/admin/builders")
    assert has_element?(view, "#throughput-#{builder.id}", "0 done, 1 failed")

    view
    |> element("#builder-#{builder.id} button[phx-click=toggle_publishing]")
    |> render_click()

    assert {:ok, %{publishing: true}} = Builders.get_builder(builder.id)

    view |> element("#lease-#{lease.id} button[phx-click=requeue]") |> render_click()
    assert Ash.get!(Lease, lease.id, domain: Builders).state == :queued

    view
    |> form("#remote-settings-form", %{
      "remote" => %{"remote_mode" => "on", "remote_backlog_threshold" => "4"}
    })
    |> render_submit()

    assert %{remote_mode: :on, remote_backlog_threshold: 4} = Portal.Settings.get()

    view |> element("#builder-#{builder.id} button[phx-click=revoke]") |> render_click()
    assert {:ok, %{status: :revoked}} = Builders.get_builder(builder.id)
  end
end
