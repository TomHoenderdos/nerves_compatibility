defmodule PortalWeb.IndexPlaceholdersTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion
  alias Portal.ScanRequests.ScanRequest

  defp seed_request(name, status) do
    {:ok, req} =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: name,
        source: :anonymous_manual,
        status: status
      })
      |> Ash.create(domain: Portal.ScanRequests)

    req
  end

  defp ingest(name) do
    dir = Path.join(System.tmp_dir!(), "idx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-07-05T10:00:00Z",
          "systems" => %{"nerves_system_rpi0" => %{"status" => "pass"}}
        },
        %{run_id: "#{name}-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )
  end

  test "accepted request not in catalog shows a placeholder linking to its progress", %{
    conn: conn
  } do
    req = seed_request("queuedpkg", :accepted)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="placeholder-queuedpkg")
    assert html =~ "in queue"
    assert html =~ ~p"/requests/#{req.id}"
  end

  test "pending (unapproved) request is not shown", %{conn: conn} do
    seed_request("pendingpkg", :pending)

    {:ok, _view, html} = live(conn, ~p"/packages")
    refute html =~ "pendingpkg"
  end

  test "a queued package already in the catalog shows only the catalog card, no placeholder", %{
    conn: conn
  } do
    ingest("dualpkg")
    seed_request("dualpkg", :accepted)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="package-dualpkg")
    refute html =~ ~s(id="placeholder-dualpkg")
  end

  test "a failed request with no build stays listed, marked build failed", %{conn: conn} do
    req = seed_request("failedpkg", :error)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="placeholder-failedpkg")
    assert html =~ "build failed"
    assert html =~ ~p"/packages/failedpkg"
    refute html =~ ~p"/requests/#{req.id}"
  end

  test "rejected requests are not listed", %{conn: conn} do
    seed_request("rejectedpkg", :rejected)

    {:ok, _view, html} = live(conn, ~p"/packages")
    refute html =~ "rejectedpkg"
  end

  test "a failed request yields to a real build of the same package", %{conn: conn} do
    ingest("rebuiltpkg")
    seed_request("rebuiltpkg", :error)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ ~s(id="package-rebuiltpkg")
    refute html =~ ~s(id="placeholder-rebuiltpkg")
  end

  test "an open request wins over an older failed one for the same package", %{conn: conn} do
    seed_request("retrypkg", :error)
    seed_request("retrypkg", :queued)

    {:ok, _view, html} = live(conn, ~p"/packages")
    assert html =~ "in queue"
    refute html =~ "build failed"
  end

  test "search filters placeholders", %{conn: conn} do
    seed_request("findme", :accepted)
    seed_request("otherpkg", :accepted)

    {:ok, view, _html} = live(conn, ~p"/packages")
    html = render_change(view, :search, %{"q" => "findme"})
    assert html =~ "placeholder-findme"
    refute html =~ "placeholder-otherpkg"
  end
end
