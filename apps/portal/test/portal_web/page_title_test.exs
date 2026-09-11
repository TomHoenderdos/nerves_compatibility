defmodule PortalWeb.PageTitleTest do
  use PortalWeb.ConnCase, async: false

  # The root layout shipped with the Phoenix scaffold's suffix, and nothing set
  # `page_title`, so every page of a public site with a sitemap was titled
  # "Portal · Phoenix Framework" -- in the browser tab and in search results.
  @suffix " · Nerves Compatibility"

  # The HEEx formatter insists on putting `{assigns[:page_title]}` on its own
  # line, so the rendered title carries the surrounding newline and indentation.
  # Browsers collapse whitespace inside `<title>`, so this is cosmetic in the
  # markup and collapsed here rather than fought in the template.
  defp title(conn) do
    [_, title] = Regex.run(~r{<title[^>]*>(.*?)</title>}s, html_response(conn, 200))

    title
    |> String.split()
    |> Enum.join(" ")
  end

  for {path, expected} <- [
        {"/", "Dashboard"},
        {"/packages", "Packages"},
        {"/failure_clusters", "Failure clusters"},
        {"/stats", "Stats"},
        {"/request-scan", "Request a scan"},
        {"/login", "Sign in"},
        {"/register", "Create an account"}
      ] do
    test "#{path} is titled #{expected}", %{conn: conn} do
      assert title(get(conn, unquote(path))) == unquote(expected) <> @suffix
    end
  end

  test "no page still carries the Phoenix scaffold suffix", %{conn: conn} do
    for path <- ~w(/ /packages /failure_clusters /stats /request-scan /login /register) do
      refute title(get(conn, path)) =~ "Phoenix Framework"
    end
  end
end
