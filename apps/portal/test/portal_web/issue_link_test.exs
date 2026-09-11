defmodule PortalWeb.IssueLinkTest do
  use PortalWeb.ConnCase, async: true

  # This deployment is a fork of fhunleth/nerves_compatibility, and the
  # request-scan template inherited the upstream repo's issue URL verbatim. The
  # "Open an issue on GitHub" link therefore sent every bug report about *this*
  # site to the upstream maintainer's tracker -- where at least one landed
  # before anyone noticed.
  #
  # The URL now lives in config. These tests are the part that keeps it from
  # drifting back: one proves the page actually renders the configured value,
  # the other proves no template has quietly hardcoded a repo again.

  @web_root "lib/portal_web"

  test "the request-scan page links to the configured tracker", %{conn: conn} do
    html = html_response(get(conn, "/request-scan"), 200)
    configured = Application.get_env(:portal, :issues_url)

    assert is_binary(configured) and configured != ""
    assert html =~ ~s(href="#{configured}")
  end

  test "the configured tracker is this fork's own, not the upstream's" do
    configured = Application.get_env(:portal, :issues_url)

    assert configured =~ "github.com/TomHoenderdos/nerves_compatibility/issues"
    refute configured =~ "fhunleth"
  end

  # A hardcoded repo URL in a template is exactly the defect this fixes, and it
  # is invisible in review -- it renders fine and points somewhere real. Fail
  # the build instead.
  test "no web template hardcodes a GitHub repository" do
    offenders =
      Path.wildcard(Path.join([@web_root, "**", "*.{ex,heex}"]))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(~r{github\.com/[\w.-]+/[\w.-]+}, line) end)
        |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "these link to a GitHub repository directly instead of reading " <>
             "`Application.get_env(:portal, :issues_url)`:\n" <> Enum.join(offenders, "\n")
  end
end
