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

  # The tracker's `POST /api/send` to the self-hosted Umami took up to 2.1s on
  # 2026-10-07. A `defer` script is part of the document's load, so the
  # browser's load indicator kept spinning until it finished; `async` is not.
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
