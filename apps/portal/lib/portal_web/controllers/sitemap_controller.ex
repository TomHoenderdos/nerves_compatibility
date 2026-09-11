defmodule PortalWeb.SitemapController do
  @moduledoc """
  `/sitemap.xml` and `/robots.txt`.

  The catalog is ~2,500 package pages that are only reachable by paginating
  `/packages`, so a crawler that never follows deep pagination never sees most
  of them. The sitemap lists every one directly.

  `robots.txt` is served from here rather than from `priv/static` so the
  `Sitemap:` directive — which must be an absolute URL — can be built from the
  endpoint's configured host instead of being hardcoded to production.
  """

  use PortalWeb, :controller

  alias Portal.Catalog

  # Pages that exist regardless of what is in the catalog. `/` changes whenever
  # a build finishes, the rest whenever the catalog does; `changefreq` and
  # `priority` are advisory and every major crawler ignores them, so they are
  # omitted rather than invented.
  @static_paths ["/", "/packages", "/failure_clusters", "/stats"]

  # One hour. The catalog moves when a build finishes, which is minutes at
  # best, and a crawler refetching this more often than hourly is not learning
  # anything new.
  @max_age 3600

  def index(conn, _params) do
    base = PortalWeb.Endpoint.url()

    body =
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
        Enum.map(@static_paths, &url_entry(base <> &1, nil)),
        Enum.map(Catalog.package_slugs(), fn pkg ->
          url_entry(base <> "/packages/" <> escape(pkg.name), pkg.last_run_at)
        end),
        ~s(</urlset>)
      ]
      |> IO.iodata_to_binary()

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
    |> send_resp(200, body)
  end

  def robots(conn, _params) do
    base = PortalWeb.Endpoint.url()

    body = """
    User-agent: *
    Disallow: /admin
    Disallow: /login
    Disallow: /register
    Disallow: /settings
    Disallow: /auth/
    Disallow: /api/

    Sitemap: #{base}/sitemap.xml
    """

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
    |> send_resp(200, body)
  end

  defp url_entry(loc, nil), do: ["<url><loc>", loc, "</loc></url>"]

  defp url_entry(loc, %DateTime{} = lastmod) do
    ["<url><loc>", loc, "</loc><lastmod>", DateTime.to_iso8601(lastmod), "</lastmod></url>"]
  end

  # Hex package names are `[A-Za-z0-9_]`, so nothing here should ever need
  # escaping — but the sitemap is generated from database rows, and a row that
  # bypassed Hex (an override, a manual insert) must not be able to emit
  # malformed XML.
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
