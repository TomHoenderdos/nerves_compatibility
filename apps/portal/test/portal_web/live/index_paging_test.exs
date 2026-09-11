defmodule PortalWeb.IndexPagingTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.ScanRequests.ScanRequest

  # `@page_size` in `PortalWeb.IndexLive`. Seeding one past it is what makes
  # these assertions non-vacuous: at 60 entries every one of them fits on the
  # first page and the button never renders.
  @page_size 60

  # Accepted scan requests render as placeholder cards through the same stream
  # as catalog packages, so they exercise paging without the cost of ingesting
  # 61 build results.
  defp seed(name) do
    {:ok, _} =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: name,
        source: :anonymous_manual,
        status: :accepted
      })
      |> Ash.create(domain: Portal.ScanRequests)
  end

  defp seed_many(n), do: for(i <- 1..n, do: seed("pkg#{String.pad_leading("#{i}", 3, "0")}"))

  defp cards(html), do: html |> String.split(~s(id="placeholder-pkg)) |> length() |> Kernel.-(1)

  test "the first render is one page, not the whole catalog", %{conn: conn} do
    seed_many(@page_size + 1)

    {:ok, _view, html} = live(conn, ~p"/packages")

    assert cards(html) == @page_size
    assert html =~ ~s(id="placeholder-pkg001")
    refute html =~ ~s(id="placeholder-pkg061")
    assert html =~ "Load more"
  end

  test "load more appends the next page and then retires the button", %{conn: conn} do
    seed_many(@page_size + 1)

    {:ok, view, _html} = live(conn, ~p"/packages")

    html = view |> element("button", "Load more") |> render_click()

    assert html =~ ~s(id="placeholder-pkg061")
    refute html =~ "Load more"
  end

  test "the count line reports the page and the total separately", %{conn: conn} do
    seed_many(@page_size + 1)

    {:ok, view, html} = live(conn, ~p"/packages")

    assert html =~ ">#{@page_size}<"
    assert html =~ ">#{@page_size + 1}<"

    html = view |> element("button", "Load more") |> render_click()
    refute html =~ "left)"
  end

  test "a search resets to a single page of its own matches", %{conn: conn} do
    seed_many(@page_size + 1)
    seed("needle")

    {:ok, view, _html} = live(conn, ~p"/packages")

    html = view |> form("#package-search", %{"q" => "needle"}) |> render_change()

    assert html =~ ~s(id="placeholder-needle")
    refute html =~ ~s(id="placeholder-pkg001")
    refute html =~ "Load more"
  end
end
