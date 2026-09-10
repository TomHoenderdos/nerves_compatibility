defmodule PortalWeb.SitemapControllerTest do
  use PortalWeb.ConnCase, async: false

  alias Portal.Catalog.Ingestion

  defp ingest(name, version) do
    dir = Path.join(System.tmp_dir!(), "sitemap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version},
      "finished_at" => "2026-07-06T10:00:00Z",
      "systems" => %{"nerves_system_rpi0" => %{"status" => "pass"}}
    }

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "#{name}-#{version}",
        image_digest: "sha256:x",
        files_dir: dir,
        scan_request_id: nil,
        log: nil
      })
  end

  describe "GET /sitemap.xml" do
    test "lists every package page", %{conn: conn} do
      ingest("alpha", "1.0.0")
      ingest("beta", "2.0.0")

      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "/packages/alpha</loc>"
      assert body =~ "/packages/beta</loc>"
    end

    test "lists the static pages a crawler would otherwise have to guess", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)

      for path <- ["/packages", "/failure_clusters", "/stats"] do
        assert body =~ "<loc>#{PortalWeb.Endpoint.url()}#{path}</loc>"
      end
    end

    test "serves valid XML as application/xml", %{conn: conn} do
      ingest("gamma", "1.0.0")

      resp = get(conn, ~p"/sitemap.xml")
      body = response(resp, 200)

      assert [content_type] = get_resp_header(resp, "content-type")
      assert content_type =~ "application/xml"
      assert String.starts_with?(body, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      assert body =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      assert String.ends_with?(body, "</urlset>")
    end

    test "dates each package page by its last run", %{conn: conn} do
      ingest("dated", "1.0.0")

      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "<lastmod>2026-07-06T10:00:00Z</lastmod>"
    end

    # Hex names cannot contain these, but the sitemap is built from database
    # rows rather than from Hex, so a row that got in another way must not be
    # able to break the document.
    test "escapes XML metacharacters in a package name", %{conn: conn} do
      ingest("a&b<c", "1.0.0")

      body = conn |> get(~p"/sitemap.xml") |> response(200)

      assert body =~ "/packages/a&amp;b&lt;c</loc>"
      refute body =~ "/packages/a&b<c</loc>"
    end

    test "is cacheable", %{conn: conn} do
      resp = get(conn, ~p"/sitemap.xml")
      assert ["public, max-age=" <> _] = get_resp_header(resp, "cache-control")
    end
  end

  describe "GET /robots.txt" do
    test "points crawlers at the sitemap using the configured host", %{conn: conn} do
      body = conn |> get(~p"/robots.txt") |> response(200)

      assert body =~ "Sitemap: #{PortalWeb.Endpoint.url()}/sitemap.xml"
    end

    test "keeps crawlers out of the pages that are not content", %{conn: conn} do
      body = conn |> get(~p"/robots.txt") |> response(200)

      for path <- ["/admin", "/login", "/register", "/settings"] do
        assert body =~ "Disallow: #{path}"
      end
    end

    test "allows the catalog itself", %{conn: conn} do
      body = conn |> get(~p"/robots.txt") |> response(200)

      assert body =~ "User-agent: *"
      refute body =~ "Disallow: /\n"
      refute body =~ "Disallow: /packages"
    end
  end
end
