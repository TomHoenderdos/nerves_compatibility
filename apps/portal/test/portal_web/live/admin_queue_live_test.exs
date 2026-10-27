defmodule PortalWeb.AdminQueueLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  import Portal.PackageListingFixtures, only: [request_fixture: 1, request_fixture: 2]

  @pw "correct horse battery staple"

  defmodule StubVersions do
    # A package named "boom" simulates the one call in the approve path
    # that can crash on a row for reasons of its own: `Portal.HexPm` itself.
    def latest_version("boom"), do: raise("simulated hex.pm crash")
    # A GenServer timeout or similar surfaces as an `exit`, not a raised
    # exception; the per-row rescue must catch this too.
    def latest_version("boom_exit"), do: exit(:boom)
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  # Stands in for a hex.pm that has not answered yet: it blocks until the
  # test says to continue, so a bulk action's test can prove the page keeps
  # answering while that lookup is still in flight.
  defmodule BlockingVersions do
    def latest_version(_package) do
      test_pid = Application.fetch_env!(:portal, :bulk_block_test_pid)
      send(test_pid, {:resolver_called, self()})

      # `after` so a test that fails before sending `:continue` cannot leave
      # this task blocked forever under `Portal.TaskSupervisor`.
      receive do
        :continue -> {:ok, "1.0.0"}
      after
        5_000 -> {:ok, "1.0.0"}
      end
    end
  end

  setup %{conn: conn} do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)

    {:ok, admin} = Portal.Accounts.seed_admin_user("cinder_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp pending(name) do
    {:ok, r} =
      Portal.ScanRequests.create_once(%{
        package_name: name,
        source: :anonymous_manual,
        status: :pending,
        subject: "anonymous",
        verification_provider: "manual_review"
      })

    r
  end

  # Both tables load with `start_async`, so their rows arrive after the mount.
  defp live_queue(conn, path \\ ~p"/admin/queue") do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view)}
  end

  # An action refreshes both tables, which reload with `start_async` too;
  # waiting for them keeps the reload from outliving the test's sandbox.
  defp click(view, event, params) do
    html = render_click(view, event, params)
    render_async(view)
    html
  end

  defp priority(request), do: Portal.Admin.queue_positions([request.id])[request.id].priority

  defp rows(html, id) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id} tbody tr[data-item-id]")
  end

  describe "access" do
    test "anonymous visitors are sent to login" do
      assert redirected_to(get(build_conn(), ~p"/admin/queue")) == ~p"/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/queue")
    end

    test "a password-only admin and a non-admin are refused", %{admin: admin} do
      conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
      assert {:error, {:redirect, %{to: "/settings/security"}}} = live(conn, ~p"/admin/queue")

      {:ok, user} = Portal.Accounts.register_user("plain_viewer", @pw)
      conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
      assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/queue")
    end

    test "the queue tab is marked current in the shared tabs", %{conn: conn} do
      {view, _html} = live_queue(conn)
      assert has_element?(view, ~s(#admin-tabs a[aria-current="page"][href="/admin/queue"]))
    end

    test "an admin demoted while the page is open is refused on the next click",
         %{conn: conn, admin: admin} do
      r = pending("demoted_pkg")
      {view, _html} = live_queue(conn)

      {:ok, _} =
        admin
        |> Ash.Changeset.for_update(:set_admin, %{is_admin: false})
        |> Ash.update(domain: Portal.Accounts)

      assert {:error, {:redirect, %{to: "/request-scan"}}} =
               render_click(view, "approve", %{"id" => r.id})

      assert {:ok, %{status: :pending}} = Portal.ScanRequests.get_request(r.id)
    end
  end

  describe "the tables" do
    test "show the scan form, waiting approvals and the queue with positions",
         %{conn: conn, admin: admin} do
      pending("admin_anon_review")
      {:ok, _} = Portal.Admin.queue_package("admin_panel_pkg", admin)
      {view, html} = live_queue(conn)

      assert has_element?(view, "#queue-package")
      assert html =~ "Queue a scan"
      assert html =~ "Anonymous approvals"
      assert html =~ "Queue position"
      assert rows(html, "approvals-table") |> LazyHTML.text() =~ "admin_anon_review"
      assert html =~ "Approve"
      queue = rows(html, "queue-table") |> LazyHTML.text()
      assert queue =~ "admin_panel_pkg"
      assert queue =~ "P0"
    end

    test "page at 50 queued and 25 waiting rows, never reading a whole table",
         %{conn: conn} do
      # 60 of each: a read of either whole table returns more than the 51
      # rows a bounded page read may, so the telemetry check below can tell
      # the two apart.
      for i <- 1..60, do: request_fixture("queued_#{i}")
      for i <- 1..60, do: request_fixture("pending_#{i}", %{status: :pending})

      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:portal, :repo, :query],
        &__MODULE__.capture_request_read/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {_view, html} = live_queue(conn)
      assert Enum.count(rows(html, "queue-table")) == 50
      assert Enum.count(rows(html, "approvals-table")) == 25
      assert_receive {:request_read, _, _}
      refute_received {:request_read, _, true}

      # Oldest first, as the controller page listed them; the second page
      # lives in the URL.
      {_view, html} = live_queue(conn, ~p"/admin/queue?page=2")
      assert [first | _] = second_page = Enum.to_list(rows(html, "queue-table"))
      assert length(second_page) == 10
      assert LazyHTML.text(first) =~ "queued_51"
    end

    test "a malformed page or sort param does not crash the page", %{conn: conn} do
      request_fixture("queued_one")

      for query <- [
            "page=oops",
            "page=-1",
            "page[]=2",
            "page[x]=2",
            "sort=nonsense",
            "page=99999999999999999999"
          ] do
        assert {:ok, view, _html} = live(conn, "/admin/queue?" <> query)
        assert rows(render_async(view), "queue-table") |> LazyHTML.text() =~ "queued_one"
      end
    end

    test "a filter change goes into the URL, so a reload keeps it", %{conn: conn} do
      request_fixture("alpha_pkg")
      request_fixture("beta_pkg")
      {view, _html} = live_queue(conn)

      view
      |> form("#queue-filter-form")
      |> render_change(%{"filters" => %{"package_name" => "beta"}})

      path = assert_patch(view)
      assert path =~ "package_name=beta"

      {_view, html} = live_queue(conn, path)
      assert rows(html, "queue-table") |> LazyHTML.text() =~ "beta_pkg"
      refute rows(html, "queue-table") |> LazyHTML.text() =~ "alpha_pkg"
    end

    test "a new request appears without reloading", %{conn: conn} do
      {view, _html} = live_queue(conn)
      pending("live_pkg")
      assert eventually(fn -> render(view) =~ "live_pkg" end)
      render_async(view)
    end
  end

  describe "row actions" do
    test "approve one request from its row", %{conn: conn} do
      r = pending("row_pkg")
      {view, _html} = live_queue(conn)

      assert click(view, "approve", %{"id" => r.id}) =~
               "Approved anonymous request for row_pkg."

      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(r.id)
    end

    test "approving a request that is no longer pending shows the existing refusal",
         %{conn: conn, admin: admin} do
      r = pending("gone_pkg")
      {:ok, _} = Portal.ScanRequests.reject_anonymous_request(r.id, admin)
      {view, _html} = live_queue(conn)

      assert click(view, "approve", %{"id" => r.id}) =~ "Request is no longer pending review."
    end

    test "reject one request from its row", %{conn: conn} do
      r = pending("reject_pkg")
      {view, _html} = live_queue(conn)

      assert click(view, "reject", %{"id" => r.id}) =~
               "Rejected anonymous request for reject_pkg."

      assert {:ok, %{status: :rejected}} = Portal.ScanRequests.get_request(r.id)
    end

    test "forged approve, reject and reprioritise clicks get the existing refusals",
         %{conn: conn} do
      {view, _html} = live_queue(conn)

      assert click(view, "approve", %{"id" => Ecto.UUID.generate()}) =~
               "Request was not found."

      assert click(view, "reject", %{"id" => "not-a-uuid"}) =~ "Request was not found."
      assert click(view, "approve", %{}) =~ "Request was not found."
      assert click(view, "reject", %{"id" => ["x"]}) =~ "Request was not found."

      assert click(view, "reprioritise", %{"id" => Ecto.UUID.generate(), "direction" => "up"}) =~
               "nothing to reorder"

      assert click(view, "reprioritise", %{}) =~ "nothing to reorder"
    end

    test "reprioritise moves the build down the queue", %{conn: conn, admin: admin} do
      {:ok, request} = Portal.Admin.queue_package("admin_priority_pkg", admin)
      {view, _html} = live_queue(conn)

      assert click(view, "reprioritise", %{"id" => request.id, "direction" => "down"}) =~
               "Moved to priority 1. Lower runs sooner."

      assert priority(request) == 1

      assert click(view, "reprioritise", %{"id" => request.id, "direction" => "up"}) =~
               "Moved to priority 0. Lower runs sooner."

      assert click(view, "reprioritise", %{"id" => request.id, "direction" => "up"}) =~
               "Already at the end of the priority range."
    end
  end

  describe "queue a package" do
    test "keeps today's message for a blank name", %{conn: conn} do
      {view, _html} = live_queue(conn)

      html =
        view
        |> form("#queue-package", %{"package_name" => "", "force" => "false"})
        |> render_submit()

      assert html =~ "Enter a package name."
      render_async(view)
    end

    test "queues a package at the front of the queue", %{conn: conn} do
      {view, _html} = live_queue(conn)

      html =
        view
        |> form("#queue-package", %{"package_name" => "admin_queued_pkg"})
        |> render_submit()

      assert html =~ "Queued admin_queued_pkg."
      render_async(view)

      request = Portal.ScanRequests.open_request_for_package("admin_queued_pkg")
      assert request.source == :admin_manual
      assert request.status == :queued
    end

    test "a forced rebuild says so", %{conn: conn} do
      {view, _html} = live_queue(conn)

      html =
        view
        |> form("#queue-package", %{"package_name" => "admin_forced_pkg", "force" => "true"})
        |> render_submit()

      assert html =~ "Queued a forced rebuild of admin_forced_pkg."
      render_async(view)
    end

    test "reports a name that cannot be a package", %{conn: conn} do
      {view, _html} = live_queue(conn)

      html =
        view
        |> form("#queue-package", %{"package_name" => "not a package name"})
        |> render_submit()

      assert html =~ "does not look like a hex.pm package name"
      assert Portal.ScanRequests.open_request_for_package("not a package name") == nil
      render_async(view)
    end

    test "says which request is already open", %{conn: conn, admin: admin} do
      {:ok, _} = Portal.Admin.queue_package("admin_dup_pkg", admin)
      {view, _html} = live_queue(conn)

      assert click(view, "queue_package", %{"package_name" => "admin_dup_pkg"}) =~
               "already has an open request"
    end

    test "a forged submit without a name is refused, not a crash", %{conn: conn} do
      {view, _html} = live_queue(conn)
      assert click(view, "queue_package", %{}) =~ "Enter a package name."
      assert click(view, "queue_package", %{"package_name" => ["x"]}) =~ "Enter a package name."
    end
  end

  describe "bulk actions" do
    test "bulk reject reports the requests it could not reject and does the rest",
         %{conn: conn, admin: admin} do
      a = pending("bulk_a")
      b = pending("bulk_b")
      {view, _html} = live_queue(conn)

      select(view, "approvals-table", a)
      select(view, "approvals-table", b)

      # Someone else gets to `b` between the selection and the click.
      {:ok, _} = Portal.ScanRequests.reject_anonymous_request(b.id, admin)

      bulk(view, "approvals-table", "Reject")

      assert render(view) =~
               "1 done, 1 refused: Request is no longer pending review."

      assert {:ok, %{status: :rejected}} = Portal.ScanRequests.get_request(a.id)
    end

    test "bulk approve approves every selected request", %{conn: conn} do
      a = pending("bulk_ok_a")
      b = pending("bulk_ok_b")
      {view, _html} = live_queue(conn)

      select(view, "approvals-table", a)
      select(view, "approvals-table", b)
      bulk(view, "approvals-table", "Approve")

      assert render(view) =~ "2 done."

      for r <- [a, b] do
        assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(r.id)
      end
    end

    test "a slow bulk resolver does not freeze the page, and the summary flash arrives once it finishes",
         %{conn: conn} do
      Application.put_env(:portal, :bulk_block_test_pid, self())
      Application.put_env(:portal, :package_version_resolver, BlockingVersions)

      on_exit(fn ->
        Application.delete_env(:portal, :bulk_block_test_pid)
        Application.put_env(:portal, :package_version_resolver, StubVersions)
      end)

      a = pending("slow_pkg")
      {view, _html} = live_queue(conn)
      select(view, "approvals-table", a)

      view
      |> element("#approvals-table span[phx-click]", "Approve")
      |> render_click()

      # Still blocked inside the task -- the old, synchronous bulk action
      # would have frozen this render along with everything else on the
      # socket.
      assert_receive {:resolver_called, resolver_pid}, 1000
      assert render(view) =~ "Working on 1 request…"
      refute render(view) =~ "Working on 1 requests…"
      refute render(view) =~ "done."

      send(resolver_pid, :continue)

      assert eventually(fn -> render(view) =~ "1 done." end)
      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(a.id)
    end

    test "a row that raises during a bulk approve is reported, and the rest still process",
         %{conn: conn} do
      a = pending("bulk_before_boom")
      boom = pending("boom")
      b = pending("bulk_after_boom")
      {view, _html} = live_queue(conn)

      select(view, "approvals-table", a)
      select(view, "approvals-table", boom)
      select(view, "approvals-table", b)
      bulk(view, "approvals-table", "Approve")

      assert render(view) =~ "2 done, 1 refused: Admin action failed."

      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(a.id)
      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(b.id)
    end

    test "a row that exits during a bulk approve is reported, and the summary still arrives",
         %{conn: conn} do
      a = pending("bulk_before_exit")
      exploder = pending("boom_exit")
      b = pending("bulk_after_exit")
      {view, _html} = live_queue(conn)

      select(view, "approvals-table", a)
      select(view, "approvals-table", exploder)
      select(view, "approvals-table", b)
      bulk(view, "approvals-table", "Approve")

      assert render(view) =~ "2 done, 1 refused: Admin action failed."

      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(a.id)
      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(b.id)
    end

    test "bulk move down and up reprioritise every selected build",
         %{conn: conn, admin: admin} do
      {:ok, a} = Portal.Admin.queue_package("bulk_move_a", admin)
      {:ok, b} = Portal.Admin.queue_package("bulk_move_b", admin)
      {view, _html} = live_queue(conn)

      select(view, "queue-table", a)
      select(view, "queue-table", b)
      bulk(view, "queue-table", "Move down")
      assert render(view) =~ "2 done."
      assert priority(a) == 1 and priority(b) == 1

      select(view, "queue-table", a)
      bulk(view, "queue-table", "Move up")
      assert priority(a) == 0 and priority(b) == 1
    end

    test "an admin demoted while the page is open is refused on the next bulk action",
         %{conn: conn, admin: admin} do
      r = pending("bulk_demoted")
      {view, _html} = live_queue(conn)
      select(view, "approvals-table", r)

      {:ok, _} =
        admin
        |> Ash.Changeset.for_update(:set_admin, %{is_admin: false})
        |> Ash.update(domain: Portal.Accounts)

      view
      |> element("#approvals-table span[phx-click]", "Approve")
      |> render_click()

      assert_redirect(view, "/request-scan")
      assert {:ok, %{status: :pending}} = Portal.ScanRequests.get_request(r.id)
    end

    test "a forged selection of a row that is not selectable is ignored",
         %{conn: conn, admin: admin} do
      {:ok, queued} = Portal.Admin.queue_package("bulk_queued", admin)
      # Accepted, not yet queued: the queue table lists it but offers no
      # checkbox. A build job is added by hand so there is a priority to
      # watch.
      accepted = request_fixture("bulk_accepted")

      {:ok, _} =
        %{package: "bulk_accepted", version: "1.0.0", scan_request_id: accepted.id}
        |> Portal.Workers.Build.new(priority: 3)
        |> Oban.insert()

      {view, _html} = live_queue(conn)

      # The accepted row's checkbox is disabled, but a client can still send
      # its id, here through the queued row's checkbox.
      assert has_element?(
               view,
               ~s(#queue-table tr[data-item-id="#{accepted.id}"] input[type="checkbox"][disabled])
             )

      view
      |> element(~s(#queue-table tr[data-item-id="#{queued.id}"] input[type="checkbox"]))
      |> render_click(%{"id" => accepted.id})

      bulk(view, "queue-table", "Move down")

      assert priority(accepted) == 3
      assert priority(queued) == 0
    end
  end

  defp select(view, table, request) do
    view
    |> element(~s(##{table} tr[data-item-id="#{request.id}"] input[type="checkbox"]))
    |> render_click()
  end

  # The click itself returns the moment the bulk work starts, not when it
  # finishes -- see `PortalWeb.Admin.QueueLive`'s moduledoc. Its summary
  # flash arrives later over a plain message, not through `start_async`, so
  # `render_async/1` alone would not wait for it. Polling for "done" alone
  # would risk matching a stale flash left over from an earlier action in
  # the same test, so this waits for the transition instead: first for the
  # "Working on" flash a real selection always sets synchronously, then for
  # it to be gone, which only happens once the task's own summary message
  # has replaced it. Neither wait is asserted: an empty selection (a forged
  # click Cinder itself ignored) runs no bulk action and so never shows a
  # "Working on" flash at all, and that is as valid an outcome as a finished
  # one. Either way the table reload a real completion triggers does go
  # through `start_async`, so it is still awaited below.
  defp bulk(view, table, label) do
    view
    |> element("##{table} span[phx-click]", label)
    |> render_click()

    eventually(fn -> render(view) =~ "Working on" end)
    eventually(fn -> not (render(view) =~ "Working on") end)
    render_async(view)
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        eventually(fun, tries - 1)
    end
  end

  def capture_request_read(_event, _measurements, metadata, test_pid) do
    if String.contains?(metadata.query, "portal_scan_requests") do
      case metadata.result do
        # A page of 50 reads 51 rows: Ash fetches one past the page to know
        # whether there is a next one.
        {:ok, %{num_rows: rows}} -> send(test_pid, {:request_read, rows, rows > 51})
        _ -> :ok
      end
    end
  end
end
