defmodule PortalWeb.NavAndStubTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "nav shows the four section links", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/stats")
    assert html =~ ~s(href="/failure_clusters")
    assert html =~ ~s(href="/stats")
    assert html =~ ~s(href="/packages")
  end

  test "warnings is not linked while the page has nothing to show", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/stats")
    refute html =~ ~s(href="/warnings")
  end
end
