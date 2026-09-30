defmodule PortalWeb.StatsLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "stats renders overall + per-system rows", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "st-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "statpkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        },
        %{run_id: "statpkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _v, html} = live(conn, ~p"/stats")
    assert html =~ "Overall Statistics"
    assert html =~ "Statistics by System"
    assert html =~ "arm64"
    assert html =~ "Unique Packages"
  end

  test "assessments are not listed as systems", %{conn: conn} do
    {:ok, _} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.2.0", nil)

    {:ok, _v, html} = live(conn, ~p"/stats")
    refute html =~ "registry_deps"
  end
end
