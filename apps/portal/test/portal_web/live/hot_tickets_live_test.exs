defmodule PortalWeb.HotTicketsLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.{Ingestion, Package}

  require Ash.Query

  defp failing(name, system \\ "nerves_system_rpi4") do
    dir = Path.join(System.tmp_dir!(), "hot-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-07-05T10:00:00Z",
          "systems" => %{
            system => %{
              "status" => "fail",
              "system_version" => "1.0.0",
              "log_tail" => "== Compilation error in file lib/x.ex =="
            }
          }
        },
        %{
          run_id: "#{name}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        }
      )
  end

  defp downloads(name, recent, all) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Portal.Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{
      hex_downloads_recent: recent,
      hex_downloads_all: all
    })
    |> Ash.update!(domain: Portal.Catalog)
  end

  defp order(html, names) do
    names
    |> Enum.map(&{&1, :binary.match(html, ~s(href="/packages/#{&1}"))})
    |> Enum.reject(fn {_name, match} -> match == :nomatch end)
    |> Enum.sort_by(fn {_name, {pos, _len}} -> pos end)
    |> Enum.map(&elem(&1, 0))
  end

  setup do
    failing("old_giant")
    downloads("old_giant", 10, 9_000_000)
    failing("rising", "nerves_system_x86_64")
    downloads("rising", 50_000, 60_000)
    :ok
  end

  test "failing packages render in recent-download order by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/failing")

    assert html =~ "Hot tickets"
    assert order(html, ["old_giant", "rising"]) == ["rising", "old_giant"]
    assert html =~ "50,000"
  end

  test "?sort=all reorders by all-time downloads", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/failing?sort=all")

    assert order(html, ["old_giant", "rising"]) == ["old_giant", "rising"]
  end

  test "?system= keeps only packages failing on that target", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/failing?system=nerves_system_x86_64")

    assert order(html, ["old_giant", "rising"]) == ["rising"]
  end

  test "changing the controls patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/failing")

    view
    |> form("#hot-tickets-filters", %{"sort" => "all", "system" => ""})
    |> render_change()

    assert_patch(view, ~p"/failing?sort=all")
    assert order(render(view), ["old_giant", "rising"]) == ["old_giant", "rising"]
  end

  test "bogus params fall back to defaults", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/failing?sort=bogus&system=")

    assert order(html, ["old_giant", "rising"]) == ["rising", "old_giant"]
  end
end
