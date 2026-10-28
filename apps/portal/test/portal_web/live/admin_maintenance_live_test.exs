defmodule PortalWeb.AdminMaintenanceLiveTest do
  use PortalWeb.ConnCase, async: false
  use Oban.Testing, repo: Portal.Repo
  import Phoenix.LiveViewTest

  @pw "correct horse battery staple"

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("cinder_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  # The sweeps table loads with `start_async`, so its rows arrive after the
  # mount.
  defp live_maintenance(conn, path \\ ~p"/admin/maintenance") do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view)}
  end

  defp built!(name) do
    {:ok, _} =
      Portal.Catalog.Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-10-10T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{run_id: "#{name}-1", image_digest: "sha256:x", files_dir: System.tmp_dir!()}
      )
  end

  defp demote!(admin) do
    {:ok, _} =
      admin
      |> Ash.Changeset.for_update(:set_admin, %{is_admin: false})
      |> Ash.update(domain: Portal.Accounts)
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  describe "access" do
    test "anonymous visitors are sent to login" do
      assert redirected_to(get(build_conn(), ~p"/admin/maintenance")) == ~p"/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/maintenance")
    end

    test "a password-only admin and a non-admin are refused", %{admin: admin} do
      conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)

      assert {:error, {:redirect, %{to: "/settings/security"}}} =
               live(conn, ~p"/admin/maintenance")

      {:ok, user} = Portal.Accounts.register_user("plain_maint", @pw)
      conn = build_conn() |> init_test_session(user_id: user.id, login_method: :password)
      assert {:error, {:redirect, %{to: "/request-scan"}}} = live(conn, ~p"/admin/maintenance")
    end

    test "the removed controller routes are gone", %{conn: conn} do
      for path <- [
            "/admin/update-check",
            "/admin/bulk-rebuild",
            "/admin/bulk-rebuild/#{Ecto.UUID.generate()}/cancel"
          ] do
        assert conn |> recycle() |> post(path) |> response(404)
      end
    end

    test "an admin demoted while the page is open is refused on the next click",
         %{conn: conn, admin: admin} do
      {view, _html} = live_maintenance(conn)
      demote!(admin)

      view
      |> form("#bulk-rebuild", %{"limit" => "5", "what" => "full"})
      |> render_submit()

      assert_redirect(view, "/request-scan")
      assert Portal.BulkRebuild.recent() == []
    end
  end

  describe "page" do
    test "keeps every section the controller page had", %{conn: conn} do
      {view, html} = live_maintenance(conn)

      assert has_element?(view, ~s(#admin-tabs a[aria-current="page"][href="/admin/maintenance"]))
      assert html =~ "hex.pm update check"
      assert has_element?(view, "#update-check")
      assert has_element?(view, "#bulk-rebuild")
      assert html =~ "nerves_system_rpi4"
      assert html =~ ~r/data-confirm="[^"]*forced Docker builds/
      assert html =~ "Cancelled also includes builds stopped"
      assert html =~ "Precompiled signing"
      assert html =~ ~s(action="/admin/maintenance/revoke-run")
      assert html =~ ~s(action="/admin/maintenance/repair-file-modes")
      assert html =~ ~s(action="/admin/maintenance/toolchain-sweep")
      assert html =~ "Toolchains"
    end

    test "a malformed page or sort param does not crash the page", %{conn: conn} do
      {:ok, %{sweep_id: id}} =
        Portal.BulkRebuild.run(limit: 1, names: ["maint_param"], created_by: "t")

      for query <- [
            "page=oops",
            "page[]=2",
            "sort=nonsense",
            "page=99999999999999999999"
          ] do
        {view, _html} = live_maintenance(conn, "/admin/maintenance?" <> query)
        assert has_element?(view, "#sweep-#{id}-remaining")
      end
    end

    test "lists sweeps newest first with their counts", %{conn: conn} do
      {:ok, %{sweep_id: old}} =
        Portal.BulkRebuild.run(limit: 1, names: ["maint_old"], created_by: "t")

      {:ok, %{sweep_id: new}} =
        Portal.BulkRebuild.run(limit: 1, names: ["maint_new"], what: :argus_only, created_by: "t")

      {view, html} = live_maintenance(conn)

      assert view |> element("#sweep-#{new}-remaining") |> render() =~ ~r/>\s*1\s*</
      assert view |> element("#sweep-#{new}-intake") |> render() =~ ~r/>\s*1\s*</
      assert view |> element("#sweep-#{new}-selected") |> render() =~ ~r/>\s*1\s*</
      assert html =~ "argus only"

      {new_at, _} = :binary.match(html, "sweep-#{new}-remaining")
      {old_at, _} = :binary.match(html, "sweep-#{old}-remaining")
      assert new_at < old_at
    end

    # Board #12: the counts column used to call `BulkRebuild.status/1` once
    # per visible row. `sweep_id` only appears in the two queries
    # `Portal.BulkRebuild.status_many/1` issues (the grouped Oban job count
    # and the grouped remote lease count); a bounded 2 here regardless of
    # how many sweeps are on the page proves the page loads counts once,
    # not per row.
    test "a page of several sweeps still costs two counts queries, not one per row",
         %{conn: conn} do
      for i <- 1..5 do
        {:ok, _} = Portal.BulkRebuild.run(limit: 1, names: ["maint_bound_#{i}"], created_by: "t")
      end

      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:portal, :repo, :query],
        &__MODULE__.capture_sweep_count_query/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {_view, _html} = live_maintenance(conn)

      assert drain_sweep_count_queries() == 2
    end
  end

  describe "bulk rebuild" do
    test "a dry run reports how many it would rebuild and starts nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/maintenance")

      html =
        view
        |> form("#bulk-rebuild", %{"limit" => "5", "what" => "full"})
        |> put_submitter(~s(button[name="mode"][value="dry_run"]))
        |> render_submit()

      assert html =~ "Dry run: would rebuild"
      assert Portal.BulkRebuild.recent() == []
    end

    test "picking targets with none ticked is refused with today's text", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/maintenance")

      html =
        view |> form("#bulk-rebuild", %{"limit" => "5", "what" => "targets"}) |> render_submit()

      assert html =~ "Pick at least one target, or choose all targets or argus only."
      assert Portal.BulkRebuild.recent() == []
    end

    test "starting one queues the sweep and lists it", %{conn: conn} do
      built!("bulkweb")
      {view, _html} = live_maintenance(conn)

      html =
        view
        |> form("#bulk-rebuild", %{"limit" => "10", "what" => "argus_only"})
        |> put_submitter(~s(button[name="mode"][value="run"]))
        |> render_submit()

      assert html =~ "Bulk rebuild queued: 1 package."
      [sweep] = Portal.BulkRebuild.recent()
      assert sweep.what == "argus_only"
      assert sweep.created_by == "cinder_admin"
      assert [_job] = all_enqueued(worker: Portal.Workers.Backfill)
      assert eventually(fn -> has_element?(view, "#sweep-#{sweep.id}-remaining") end)
    end

    test "only the ticked known targets are rebuilt", %{conn: conn} do
      built!("bulktargets")
      {view, _html} = live_maintenance(conn)

      view
      |> form("#bulk-rebuild", %{
        "limit" => "10",
        "what" => "targets",
        "systems" => ["nerves_system_rpi4"]
      })
      |> put_submitter(~s(button[name="mode"][value="run"]))
      |> render_submit()

      [sweep] = Portal.BulkRebuild.recent()
      assert sweep.what == "targets"
      assert sweep.systems == ["nerves_system_rpi4"]
    end

    test "a forged submit with nonsense values falls back to the defaults", %{conn: conn} do
      {view, _html} = live_maintenance(conn)

      html =
        render_submit(view, "bulk_rebuild", %{
          "limit" => %{"x" => "1"},
          "what" => ["full"],
          "systems" => "not a list",
          "mode" => "dry_run"
        })

      assert html =~ "Dry run: would rebuild 0 packages."
    end

    test "a new sweep appears without reloading", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/maintenance")

      {:ok, %{sweep_id: id}} =
        Portal.BulkRebuild.run(limit: 1, names: ["maint_evt"], created_by: "t")

      assert eventually(fn -> has_element?(view, "#sweep-#{id}-remaining") end)
    end
  end

  describe "remote builds" do
    # A remote build's job completes as soon as it has written its lease, so
    # from then on only the lease moves, and a lease announces itself on
    # `:builders`, not `:sweeps`.
    test "a lease state change while the page is open refreshes the sweep counts",
         %{conn: conn} do
      {:ok, %{sweep_id: id}} =
        Portal.BulkRebuild.run(limit: 1, names: ["remote_sweep"], created_by: "t")

      request_id = Ecto.UUID.generate()

      job =
        %{package: "remote_sweep", version: "1.0.0", scan_request_id: request_id}
        |> Portal.Workers.RemoteBuild.new(meta: %{sweep_id: id})
        |> Oban.insert!()

      Portal.Repo.update!(Ecto.Changeset.change(job, state: "completed"))

      {:ok, _lease} =
        Portal.Builders.Leases.enqueue(%{
          package: "remote_sweep",
          version: "1.0.0",
          image_name: "i",
          image_digest: "sha256:d",
          args: %{},
          scan_request_id: request_id
        })

      builder =
        Portal.Builders.Builder
        |> Ash.Changeset.for_create(:enrol, %{
          name: "maint-builder",
          fingerprint: "fp-maint-builder",
          cert_pem: "p",
          cert_expires_at: DateTime.utc_now(),
          slots: 1,
          enrolled_at: DateTime.utc_now()
        })
        |> Ash.create!(domain: Portal.Builders)

      {view, _html} = live_maintenance(conn)
      assert view |> element("#sweep-#{id}-building") |> render() =~ ~r/>\s*0\s*</

      {:ok, _} = Portal.Builders.Leases.claim(builder)

      assert eventually(fn ->
               view |> element("#sweep-#{id}-building") |> render() =~ ~r/>\s*1\s*</
             end)

      render_async(view)
    end
  end

  describe "cancelling sweeps" do
    test "cancelling selected sweeps cancels their waiting jobs", %{conn: conn} do
      {:ok, %{sweep_id: id}} =
        Portal.BulkRebuild.run(limit: 1, names: ["maint_cancel"], created_by: "t")

      {:ok, view, _} = live(conn, ~p"/admin/maintenance")
      assert render_click(view, "cancel_sweep", %{"id" => id}) =~ "Cancelled 1 waiting jobs."
    end

    test "a forged sweep id is refused with today's text", %{conn: conn} do
      {view, _html} = live_maintenance(conn)

      for id <- ["nope", nil, %{"x" => "y"}] do
        assert render_click(view, "cancel_sweep", %{"id" => id}) =~ "That sweep id is not valid."
      end
    end

    test "bulk cancel stops every selected sweep's waiting jobs", %{conn: conn} do
      {:ok, %{sweep_id: a}} =
        Portal.BulkRebuild.run(limit: 1, names: ["bulk_c_a"], created_by: "t")

      {:ok, %{sweep_id: b}} =
        Portal.BulkRebuild.run(limit: 1, names: ["bulk_c_b"], created_by: "t")

      {view, _html} = live_maintenance(conn)

      for id <- [a, b] do
        view
        |> element(~s(#sweeps-table tr[data-item-id="#{id}"] input[type="checkbox"]))
        |> render_click()
      end

      view |> element("#sweeps-table span[phx-click]", "Cancel") |> render_click()
      render_async(view)

      assert render(view) =~ "Cancelled 2 waiting jobs."
      assert all_enqueued(worker: Portal.Workers.Backfill) == []
      assert Enum.all?(Portal.BulkRebuild.recent(), & &1.cancelled_at)
    end

    @tag :capture_log
    test "an admin demoted while the page is open is refused on the next bulk cancel",
         %{conn: conn, admin: admin} do
      {:ok, %{sweep_id: id}} =
        Portal.BulkRebuild.run(limit: 1, names: ["bulk_c_demoted"], created_by: "t")

      {view, _html} = live_maintenance(conn)

      view
      |> element(~s(#sweeps-table tr[data-item-id="#{id}"] input[type="checkbox"]))
      |> render_click()

      demote!(admin)
      view |> element("#sweeps-table span[phx-click]", "Cancel") |> render_click()

      assert_redirect(view, "/request-scan")
      assert [_job] = all_enqueued(worker: Portal.Workers.Backfill)
    end
  end

  describe "update check" do
    test "run now queues a check and says so", %{conn: conn} do
      {view, _html} = live_maintenance(conn)

      html =
        view
        |> form("#update-check")
        |> put_submitter(~s(button[name="mode"][value="run"]))
        |> render_submit()

      assert html =~ "Update check queued."
      assert Portal.Admin.update_check_status().pending?
      assert has_element?(view, "#update-check button[value=run][disabled]")
    end

    test "a dry run queues nothing but a report", %{conn: conn} do
      {view, _html} = live_maintenance(conn)

      html =
        view
        |> form("#update-check")
        |> put_submitter(~s(button[name="mode"][value="dry_run"]))
        |> render_submit()

      assert html =~ "Dry run queued. It reports what it would rebuild and queues nothing."
    end
  end

  def capture_sweep_count_query(_event, _measurements, metadata, test_pid) do
    if String.contains?(metadata.query, "sweep_id") do
      send(test_pid, :sweep_count_query)
    end
  end

  defp drain_sweep_count_queries(n \\ 0) do
    receive do
      :sweep_count_query -> drain_sweep_count_queries(n + 1)
    after
      0 -> n
    end
  end

  describe "build cache L2" do
    test "shows the eviction counters and the size mark", %{conn: conn} do
      previous = Application.get_env(:portal, Portal.BuildCache.L2, [])

      Application.put_env(:portal, Portal.BuildCache.L2,
        endpoint: "http://192.0.2.10:3900",
        bucket: "ncc-build-cache",
        access_key: "GK1",
        secret_key: "s",
        max_gb: "50"
      )

      on_exit(fn ->
        Application.put_env(:portal, Portal.BuildCache.L2, previous)
        Portal.BuildCache.L2.Stats.reset()
      end)

      Portal.BuildCache.L2.Stats.reset()
      Portal.BuildCache.L2.Stats.record(:evicted, 4096)

      {view, _html} = live_maintenance(conn)
      card = view |> element("#build-cache-l2") |> render()
      assert card =~ "Evictions"
      assert card =~ "1 (4096 bytes)"
      assert card =~ "50 GB"
    end

    test "shows no size mark when none is set", %{conn: conn} do
      previous = Application.get_env(:portal, Portal.BuildCache.L2, [])

      Application.put_env(:portal, Portal.BuildCache.L2,
        endpoint: "http://192.0.2.10:3900",
        bucket: "ncc-build-cache",
        access_key: "GK1",
        secret_key: "s"
      )

      on_exit(fn -> Application.put_env(:portal, Portal.BuildCache.L2, previous) end)

      {view, _html} = live_maintenance(conn)
      card = view |> element("#build-cache-l2") |> render()
      assert card =~ "Evictions"
      refute card =~ "oldest objects"
    end

    test "shows the L2 build cache off", %{conn: conn} do
      {view, _html} = live_maintenance(conn)
      card = view |> element("#build-cache-l2") |> render()
      assert card =~ "Build cache L2"
      assert card =~ "Off"
    end

    test "shows the L2 endpoint and counters, never the keys", %{conn: conn} do
      previous = Application.get_env(:portal, Portal.BuildCache.L2, [])

      Application.put_env(:portal, Portal.BuildCache.L2,
        endpoint: "http://100.64.0.2:3900",
        bucket: "ncc-build-cache",
        access_key: "GKVISIBLE",
        secret_key: "topsecret",
        read_only: true
      )

      on_exit(fn ->
        Application.put_env(:portal, Portal.BuildCache.L2, previous)
        Portal.BuildCache.L2.Stats.reset()
      end)

      Portal.BuildCache.L2.Stats.reset()
      Portal.BuildCache.L2.Stats.record(:download_ok, 1234)

      {_view, html} = live_maintenance(conn)
      assert html =~ "http://100.64.0.2:3900/ncc-build-cache"
      assert html =~ "read-only"
      assert html =~ "Downloads"
      refute html =~ "GKVISIBLE"
      refute html =~ "topsecret"
    end
  end
end
