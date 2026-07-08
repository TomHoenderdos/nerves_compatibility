defmodule PortalWeb.DashboardLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "dashboard renders summary + tiles + recent lists", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Unique Packages"
    assert html =~ "Passing"
    assert html =~ "Failing"
    assert html =~ "Top failure clusters"
    assert html =~ "Native code"
    assert html =~ "Pass rate per system"
    assert html =~ "Recently checked passing"
    assert html =~ "Recently checked failing"
  end

  test "dashboard shows a failure cluster and a recent failing package with data", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "dashfail", "version" => "1.0.0"},
          "finished_at" => "2026-07-04T10:00:00Z",
          "systems" => %{
            "nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"}
          }
        },
        %{run_id: "dashfail-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "NIF built for wrong architecture"
    assert html =~ "dashfail"
  end
end
