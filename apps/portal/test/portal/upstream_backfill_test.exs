defmodule Portal.UpstreamBackfillTest do
  use ExUnit.Case, async: true

  alias Portal.UpstreamBackfill

  # The upstream page is one long line per literal. The interesting hazards are
  # both in here: a second literal after ROWS, and a `];` inside a description.
  @html """
  <html><body><script>
      const ROWS = [{"name":"a11y_audit","version":"0.3.2","description":"lists like [a]; and more"},{"name":"jason","version":"1.4.4"}];
      const PLACEHOLDERS = [{"name":"absinthe_phoenix"}];
    </script></body></html>
  """

  test "reads every scanned package and stops at the end of the literal" do
    assert UpstreamBackfill.extract_names(@html, "ROWS") == ["a11y_audit", "jason"]
  end

  test "reads the placeholder literal separately" do
    assert UpstreamBackfill.extract_names(@html, "PLACEHOLDERS") == ["absinthe_phoenix"]
  end

  test "returns nothing when the literal is absent" do
    assert UpstreamBackfill.extract_names("<html></html>", "ROWS") == []
  end
end
