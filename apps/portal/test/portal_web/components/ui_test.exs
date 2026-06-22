defmodule PortalWeb.UITest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PortalWeb.UI

  test "status_badge renders the status text and a pass color in light + dark" do
    html = render_component(&status_badge/1, status: "pass")
    assert html =~ "pass"
    assert html =~ "emerald"
    assert html =~ "dark:"
  end

  test "page_header renders kicker, title and an actions slot" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PortalWeb.UI.page_header kicker="Catalog" title="Nerves Compatibility">
        <:actions><a href="/x">Go</a></:actions>
      </PortalWeb.UI.page_header>
      """)

    assert html =~ "Catalog"
    assert html =~ "Nerves Compatibility"
    assert html =~ "Go"
  end

  test "system_bar renders one segment per status" do
    html = render_component(&system_bar/1, statuses: ["pass", "fail", "skipped"])
    assert html |> String.split("rounded-full") |> length() >= 4
  end

  test "stat_card renders label and value" do
    html = render_component(&stat_card/1, label: "Systems", value: "6")
    assert html =~ "Systems"
    assert html =~ "6"
  end
end
