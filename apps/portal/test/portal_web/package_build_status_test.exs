defmodule PortalWeb.PackageBuildStatusTest do
  use PortalWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion
  alias Portal.ScanRequests
  alias Portal.ScanRequests.ScanRequest

  defp seed_request(name, status, attrs \\ %{}) do
    {:ok, req} =
      ScanRequest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{package_name: name, source: :anonymous_manual, status: status}, attrs)
      )
      |> Ash.create(domain: Portal.ScanRequests)

    req
  end

  defp fail(req, reason, log) do
    {:ok, req} = ScanRequests.set_status(req.id, :error, error_reason: reason, error_log: log)
    req
  end

  defp ingest(name) do
    dir = Path.join(System.tmp_dir!(), "pkgstatus-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-07-05T10:00:00Z",
          "systems" => %{"nerves_system_rpi0" => %{"status" => "pass"}}
        },
        %{
          run_id: "#{name}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        }
      )
  end

  # `Portal.Admin.queue_positions/1` reads the build job's Oban state; a test
  # has no queue running, so the job is put into `executing` by hand.
  defp start_building(req) do
    {:ok, job} =
      %{package: req.package_name, version: "1.0.0", scan_request_id: req.id}
      |> Portal.Workers.Build.new()
      |> Oban.insert()

    Portal.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing"]
    )
  end

  defp stage(view, key, state),
    do: has_element?(view, ~s(#build-stage-#{key}[data-state="#{state}"]))

  describe "a package with no results" do
    test "an unreviewed request is waiting for review, with no stage list", %{conn: conn} do
      seed_request("reviewpkg", :pending)

      {:ok, view, _html} = live(conn, ~p"/packages/reviewpkg")

      assert has_element?(view, "#package-pending #request-status", "Waiting for review")
      refute has_element?(view, "#build-stages")
    end

    test "a queued package shows the stage list at queued", %{conn: conn} do
      seed_request("waitingpkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/waitingpkg")

      assert has_element?(view, "#package-pending #request-status", "Queued")
      assert stage(view, "queued", "active")
      assert stage(view, "building", "pending")
      assert has_element?(view, ~s(#package-pending a[href="https://hex.pm/packages/waitingpkg"]))
    end

    test "there is no link to a separate request page", %{conn: conn} do
      seed_request("nolinkpkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/nolinkpkg")

      refute has_element?(view, ~s(a[href^="/requests/"]))
    end

    test "a package whose build job is running is building", %{conn: conn} do
      req = seed_request("buildingpkg", :queued)
      start_building(req)

      {:ok, view, _html} = live(conn, ~p"/packages/buildingpkg")

      assert has_element?(view, "#request-status", "Building")
      assert stage(view, "queued", "done")
      assert stage(view, "building", "active")
      assert stage(view, "ingesting", "pending")
    end

    test "a failed package leads with why it failed and opens the log at its end", %{
      conn: conn
    } do
      log =
        String.duplicate("    warning: found quoted keyword \"x\"\n", 50) <>
          "** (ErlangError) Erlang error: {:invalid_byte, 130}\n" <>
          "    (stdlib 8.1) json.erl:543: :json.invalid_byte/2\n"

      "brokenpkg" |> seed_request(:pending) |> fail("worker/runner exit 1", log)

      {:ok, view, _html} = live(conn, ~p"/packages/brokenpkg")

      assert has_element?(view, "#request-status", "Build failed")
      assert has_element?(view, "#request-failure-summary", "invalid_byte, 130")
      refute has_element?(view, "#request-failure-summary", "quoted keyword")
      assert has_element?(view, "#request-error-log", "worker/runner exit 1")
      # The scroller is reversed, so the browser starts it at the bottom.
      assert has_element?(view, "#request-error-log [data-starts-at-end]")
    end

    test "a failure without a recognisable cause shows only the log", %{conn: conn} do
      "quietpkg" |> seed_request(:pending) |> fail("worker/runner exit 20", "nothing to see\n")

      {:ok, view, _html} = live(conn, ~p"/packages/quietpkg")

      refute has_element?(view, "#request-failure-summary")
      assert has_element?(view, "#request-error-log", "nothing to see")
    end

    test "the newest request decides the status", %{conn: conn} do
      seed_request("againpkg", :error)
      seed_request("againpkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/againpkg")
      assert has_element?(view, "#request-status", "Queued")
      refute has_element?(view, "#request-error-log")
    end

    test "a rejected-only package is still not found", %{conn: conn} do
      seed_request("nopepkg", :rejected)

      assert {:error, {:live_redirect, %{to: "/packages"}}} = live(conn, ~p"/packages/nopepkg")
    end

    test "an unknown package is still not found", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/packages"}}} = live(conn, ~p"/packages/nosuchpkg")
    end
  end

  describe "a package with results" do
    test "a newer open request shows a New build card above the results", %{conn: conn} do
      ingest("rebuiltpkg")
      seed_request("rebuiltpkg", :queued)

      {:ok, view, html} = live(conn, ~p"/packages/rebuiltpkg")

      assert has_element?(view, "#package-new-build #request-status", "Queued")
      assert has_element?(view, "#package-results")

      {new_build, _} = :binary.match(html, ~s(id="package-new-build"))
      {results, _} = :binary.match(html, ~s(id="package-results"))
      assert new_build < results
    end

    test "a failure older than the latest run is not shown", %{conn: conn} do
      "stalefailpkg" |> seed_request(:pending) |> fail("worker/runner exit 1", "old\n")
      ingest("stalefailpkg")

      {:ok, view, _html} = live(conn, ~p"/packages/stalefailpkg")

      assert has_element?(view, "#package-results")
      refute has_element?(view, "#package-new-build")
    end

    test "a failure newer than the latest run is shown", %{conn: conn} do
      ingest("freshfailpkg")

      "freshfailpkg"
      |> seed_request(:pending)
      |> fail("worker/runner exit 1", "** (RuntimeError) rebuild broke\n")

      {:ok, view, _html} = live(conn, ~p"/packages/freshfailpkg")

      assert has_element?(view, "#package-new-build #request-status", "Build failed")
      assert has_element?(view, "#package-new-build #request-failure-summary", "rebuild broke")
    end

    test "a built request is never shown", %{conn: conn} do
      ingest("donepkg")
      seed_request("donepkg", :built)

      {:ok, view, _html} = live(conn, ~p"/packages/donepkg")

      refute has_element?(view, "#package-new-build")
    end
  end

  describe "live updates" do
    test "an ingesting broadcast moves the stage list on", %{conn: conn} do
      req = seed_request("livepkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/livepkg")
      assert stage(view, "ingesting", "pending")

      Phoenix.PubSub.broadcast(
        Portal.PubSub,
        "request:#{req.id}",
        {:build_progress, :ingesting, %{run_id: "r"}}
      )

      assert stage(view, "building", "done")
      assert stage(view, "ingesting", "active")
    end

    test "a done broadcast reloads the page so the results appear", %{conn: conn} do
      req = seed_request("finishingpkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/finishingpkg")

      {:ok, _} = ScanRequests.set_status(req, :built)

      Phoenix.PubSub.broadcast(
        Portal.PubSub,
        "request:#{req.id}",
        {:build_progress, :done, %{status: :pass}}
      )

      assert_redirect(view, ~p"/packages/finishingpkg")
    end

    test "an error broadcast shows the failure", %{conn: conn} do
      req = seed_request("dyingpkg", :queued)

      {:ok, view, _html} = live(conn, ~p"/packages/dyingpkg")
      refute has_element?(view, "#request-error-log")

      fail(req, "worker/runner exit 10", "== Compilation error in file lib/x.ex ==\n")

      Phoenix.PubSub.broadcast(
        Portal.PubSub,
        "request:#{req.id}",
        {:build_progress, :error, %{reason: "worker/runner exit 10"}}
      )

      assert has_element?(view, "#request-error-log", "Compilation error")
      assert has_element?(view, "#request-status", "Build failed")
    end
  end
end
