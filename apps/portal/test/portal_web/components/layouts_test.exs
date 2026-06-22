defmodule PortalWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  test "app shell renders the Nerves Compatibility nav, not the Phoenix scaffold nav" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PortalWeb.Layouts.app flash={%{}}>
        <p>content here</p>
      </PortalWeb.Layouts.app>
      """)

    assert html =~ "site-nav"
    assert html =~ "Nerves Compatibility"
    assert html =~ "content here"
    refute html =~ "Get Started"
    refute html =~ "phoenixframework.org"
  end
end
