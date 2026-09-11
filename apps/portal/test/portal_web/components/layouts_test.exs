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

  # Regression: the `hidden` attribute is the only thing keeping these toasts off
  # the page, so `JS.remove_attribute("hidden")` without a `to:` -- which targets
  # the element carrying the binding -- un-hid the server-error toast on *every*
  # disconnect, an ordinary reload included. Each command in the chain has to name
  # the same selector as the `show/1` it is piped onto.
  test "a disconnect toast un-hides only itself, and only for its own error class" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <PortalWeb.Layouts.flash_group flash={%{}} id="flash-group" />
      """)

    for kind <- ~w(client server) do
      selector = ".phx-#{kind}-error ##{kind}-error"

      commands =
        Regex.run(~r/id="#{kind}-error".*?phx-disconnected="([^"]*)"/s, html)
        |> List.last()
        |> String.replace("&quot;", ~s("))
        |> String.replace("&amp;", "&")
        |> Jason.decode!()

      assert Enum.any?(commands, fn [name, _] -> name == "remove_attr" end),
             "#{kind}-error no longer removes the hidden attribute"

      for [name, opts] <- commands do
        assert opts["to"] == selector,
               "#{kind}-error runs #{name} against #{inspect(opts["to"])} " <>
                 "rather than #{selector}, so it fires on any disconnect"
      end
    end
  end
end
