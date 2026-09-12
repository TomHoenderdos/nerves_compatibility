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

  describe "the pass-rate-per-system tile" do
    defp ingest_systems(name, systems) do
      dir = Path.join(System.tmp_dir!(), "dash-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, _} =
        Ingestion.ingest(
          %{
            "package" => %{"name" => name, "version" => "1.0.0"},
            "finished_at" => "2026-07-04T10:00:00Z",
            "systems" => systems
          },
          %{run_id: "#{name}-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
        )
    end

    # `forced@admin@unknown` is the placeholder `NccWorker.Worker` writes when a
    # package is skipped administratively. It is not a Nerves system, and it can
    # never pass, so listing it means a permanent 0% row in a tile about how
    # well each system builds.
    test "the synthetic forced bucket is not a row", %{conn: conn} do
      ingest_systems("skipped", %{"forced@admin@unknown" => %{"status" => "skipped"}})

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "forced@admin@unknown"
      refute html =~ "admin@unknown"
    end

    # The shared `nerves_system_` prefix is what pushed the longest name onto a
    # second line in a third-width tile. The full name has to stay reachable,
    # which is what the `title` attribute is for.
    test "a system is labelled without the prefix every system shares", %{conn: conn} do
      ingest_systems("riscv", %{"nerves_system_mangopi_mq_pro" => %{"status" => "pass"}})

      {:ok, _view, html} = live(conn, ~p"/")

      # Anchored on the element boundaries, because the full name is also in the
      # markup as the `title` -- a bare `=~ "mangopi_mq_pro"` would pass whether
      # the prefix were stripped or not.
      assert html =~ ~r/>\s*mangopi_mq_pro\s*</
      assert html =~ ~s(title="nerves_system_mangopi_mq_pro")
    end
  end
end
