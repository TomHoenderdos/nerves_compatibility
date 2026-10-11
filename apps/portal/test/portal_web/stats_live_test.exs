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

  # The worker skips the other targets once the host and rpi4 both fail. Those
  # skips are counted, so a target's Total stays comparable with rpi4's.
  test "skipped targets have their own column and count in the total", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "st-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "skippkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{
            "host" => %{"status" => "fail"},
            "nerves_system_rpi4" => %{"status" => "fail"},
            "nerves_system_bbb" => %{
              "status" => "skipped",
              "error" => "host and nerves_system_rpi4 failed to compile"
            }
          }
        },
        %{run_id: "skippkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, view, html} = live(conn, ~p"/stats")
    assert html =~ "Skipped"

    bbb = view |> element("tr", "nerves_system_bbb") |> render()
    assert bbb =~ ~r/<td[^>]*>\s*1\s*<\/td>\s*<td[^>]*>\s*0\s*<\/td>/
    assert bbb =~ ~r/data-col="skipped"[^>]*>\s*1\s*</
  end

  test "assessments are not listed as systems", %{conn: conn} do
    {:ok, _} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.2.0", nil)

    {:ok, _v, html} = live(conn, ~p"/stats")
    refute html =~ "registry_deps"
  end
end
