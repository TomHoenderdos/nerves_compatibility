defmodule PortalWeb.CinderThemeTest do
  use ExUnit.Case, async: true

  test "the portal theme resolves and uses daisyUI classes" do
    theme = Cinder.Theme.merge(PortalWeb.CinderTheme)
    assert theme.table_class =~ "table"
  end
end
