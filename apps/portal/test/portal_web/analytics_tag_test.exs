defmodule PortalWeb.AnalyticsTagTest do
  # Not async: it sets application env the root layout reads.
  use PortalWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:portal, :umami_website_id)
    on_exit(fn -> Application.put_env(:portal, :umami_website_id, previous) end)
  end

  defp analytics_tag(conn) do
    case Regex.run(~r{<script[^>]*analytics\.tomhoenderdos\.nl[^>]*>}s, html_response(conn, 200)) do
      [tag] -> tag
      nil -> nil
    end
  end

  # `async` keeps the tracker from delaying DOMContentLoaded, and still lets it
  # read its website id from `document.currentScript`. The attributes it needs
  # (Rocket Loader opt-out, performance metrics, site id) must survive.
  test "the Umami tag loads async, not deferred", %{conn: conn} do
    Application.put_env(:portal, :umami_website_id, "site-id-123")

    tag = analytics_tag(get(conn, "/"))

    assert tag =~ ~r/\sasync[\s>=]/
    refute tag =~ ~r/\sdefer[\s>=]/
    assert tag =~ ~s(data-cfasync="false")
    assert tag =~ ~s(data-performance="true")
    assert tag =~ ~s(data-website-id="site-id-123")
  end

  test "no tag without a website id", %{conn: conn} do
    Application.delete_env(:portal, :umami_website_id)

    assert analytics_tag(get(conn, "/")) == nil
  end
end
