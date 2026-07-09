defmodule PortalWeb.FailureClustersLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "empty state with no failures", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/failure_clusters")
    assert html =~ "Failure clusters"
    assert html =~ "No failure clusters"
  end

  test "renders a cluster card with affected package and sample log", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "fc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "fcpkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{
            "nerves_system_rpi4" => %{
              "status" => "fail",
              "log_tail" => "cannot execute binary file: Exec format error"
            }
          }
        },
        %{run_id: "fcpkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _v, html} = live(conn, ~p"/failure_clusters")
    assert html =~ "NIF built for wrong architecture"
    assert html =~ "fcpkg"
    assert html =~ "Exec format error"
  end
end
