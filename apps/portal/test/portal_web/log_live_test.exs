defmodule PortalWeb.LogLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  defp seed(body) do
    files = Path.join(System.tmp_dir!(), "ll-f-#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "ll-o-#{System.unique_integer([:positive])}")
    File.mkdir_p!(files)
    File.mkdir_p!(Path.join(out, "logs"))
    File.write!(Path.join([out, "logs", "nerves_system_rpi4.log"]), body)

    on_exit(fn ->
      File.rm_rf(files)
      File.rm_rf(out)
    end)

    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "logpkg", "version" => "1.0.0"},
          "finished_at" => "2026-09-10T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "fail"}}
        },
        %{
          run_id: "logpkg-1",
          image_digest: "sha256:x",
          files_dir: files,
          output_dir: out,
          log: "runner"
        }
      )

    :ok
  end

  test "renders the log body", %{conn: conn} do
    seed("alpha line\nbeta line\ngamma line\n")

    {:ok, view, _html} = live(conn, ~p"/packages/logpkg/log/nerves_system_rpi4")

    assert has_element?(view, "#log-body", "alpha line")
    assert has_element?(view, "#log-body", "gamma line")
    assert has_element?(view, "#log-line-count")
  end

  test "the filter narrows the rendered lines, case-insensitively", %{conn: conn} do
    seed("alpha line\nbeta line\ngamma line\n")

    {:ok, view, _html} = live(conn, ~p"/packages/logpkg/log/nerves_system_rpi4")

    view |> element("#log-filter-form") |> render_change(%{"filter" => "BETA"})

    assert has_element?(view, "#log-body", "beta line")
    refute has_element?(view, "#log-body", "alpha line")
  end

  test "renders a script tag as text, never as markup", %{conn: conn} do
    seed("<script>alert(1)</script>\n")

    {:ok, _view, html} = live(conn, ~p"/packages/logpkg/log/nerves_system_rpi4")

    # A raw-HTML assertion on purpose: the whole point is what bytes reach the
    # browser, which has no DOM-id equivalent.
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)</script>"
  end

  test "redirects to the package page when no log is stored", %{conn: conn} do
    seed("x\n")

    assert {:error, {:live_redirect, %{to: "/packages/logpkg"}}} =
             live(conn, ~p"/packages/logpkg/log/nerves_system_x86_64")
  end

  test "the package page links a failed system to its log", %{conn: conn} do
    seed("x\n")

    {:ok, view, _html} = live(conn, ~p"/packages/logpkg")

    assert has_element?(view, "#log-link-nerves-system-rpi4")
  end
end
