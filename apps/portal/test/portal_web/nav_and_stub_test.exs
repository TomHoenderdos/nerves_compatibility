defmodule PortalWeb.NavAndStubTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "warnings stub renders", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/warnings")
    assert html =~ "Warnings"
    assert html =~ "coming soon"
  end

  test "nav shows the five section links", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/warnings")
    assert html =~ ~s(href="/failure_clusters")
    assert html =~ ~s(href="/stats")
    assert html =~ ~s(href="/warnings")
    assert html =~ ~s(href="/packages")
  end
end
