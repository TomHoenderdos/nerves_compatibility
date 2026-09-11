defmodule PortalWeb.PageMetaTest do
  use PortalWeb.ConnCase, async: false

  alias Portal.Catalog.Ingestion

  # Every page here is public and listed in sitemap.xml, and before this the
  # only meta tags in the document were charset, viewport and the CSRF token.
  # A search engine therefore invented its own snippet for all ~2,500 indexed
  # URLs, and a link pasted into Slack or Discord unfurled as a bare URL.

  @public ~w(/ /packages /failure_clusters /stats /request-scan /login /register)

  defp meta(html, name) do
    case Regex.run(~r/<meta name="#{name}" content="([^"]*)"/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp og(html, property) do
    case Regex.run(~r/<meta property="#{property}" content="([^"]*)"/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp canonical(html) do
    case Regex.run(~r/<link rel="canonical" href="([^"]*)"/, html) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp title(html) do
    [_, title] = Regex.run(~r{<title[^>]*>(.*?)</title>}s, html)
    title |> String.split() |> Enum.join(" ")
  end

  defp fetch(conn, path), do: html_response(get(conn, path), 200)

  describe "every public page" do
    test "carries a description of its own", %{conn: conn} do
      described =
        Map.new(@public, fn path -> {path, meta(fetch(conn, path), "description")} end)

      for {path, description} <- described do
        assert is_binary(description) and description != "",
               "#{path} has no meta description"
      end

      # A single shared string across every page would satisfy the assertion
      # above while telling a crawler nothing. These are distinct pages.
      assert described |> Map.values() |> Enum.uniq() |> length() == length(@public)
    end

    test "declares a canonical URL that matches its own path", %{conn: conn} do
      base = PortalWeb.Endpoint.url()

      for path <- @public do
        assert canonical(fetch(conn, path)) == base <> path
      end
    end

    test "repeats its title and description as Open Graph", %{conn: conn} do
      for path <- @public do
        html = fetch(conn, path)

        assert og(html, "og:title") == title(html)
        assert og(html, "og:description") == meta(html, "description")
        assert og(html, "og:url") == canonical(html)
        assert og(html, "og:site_name") == "Nerves Compatibility"
        assert meta(html, "twitter:card") == "summary"
      end
    end
  end

  # A canonical that keeps the query string defeats the point: whoever shares a
  # link appends utm_* or fbclid, and each variant is then indexed as a separate
  # duplicate of the same page.
  test "the canonical URL drops tracking parameters", %{conn: conn} do
    html = fetch(conn, "/packages?utm_source=newsletter&fbclid=abc123")

    assert canonical(html) == PortalWeb.Endpoint.url() <> "/packages"
  end

  describe "a package page" do
    defp ingest(name, version, systems, description) do
      dir = Path.join(System.tmp_dir!(), "meta-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      result = %{
        "package" => %{
          "name" => name,
          "version" => version,
          "description" => description
        },
        "finished_at" => "2026-09-11T10:00:00Z",
        "systems" => systems
      }

      {:ok, _} =
        Ingestion.ingest(result, %{
          run_id: "#{name}-#{version}",
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        })
    end

    test "describes its own package rather than the site", %{conn: conn} do
      ingest(
        "mixedpkg",
        "1.2.3",
        %{
          "nerves_system_rpi4" => %{"status" => "pass"},
          "nerves_system_x86_64" => %{"status" => "fail", "log_tail" => "boom"}
        },
        "An image processing library."
      )

      description = meta(fetch(conn, "/packages/mixedpkg"), "description")

      assert description =~ "mixedpkg 1.2.3"
      assert description =~ "1 of 2"
      assert description =~ "An image processing library."
    end

    test "says so plainly when every system passes or every system fails", %{conn: conn} do
      ingest("allgood", "2.0.0", %{"nerves_system_rpi4" => %{"status" => "pass"}}, nil)
      ingest("allbad", "3.0.0", %{"nerves_system_rpi4" => %{"status" => "fail"}}, nil)

      assert meta(fetch(conn, "/packages/allgood"), "description") =~
               "builds on all 1 tracked Nerves systems"

      assert meta(fetch(conn, "/packages/allbad"), "description") =~
               "fails on all 1 tracked Nerves systems"
    end

    # The blurb is upstream text from Hex, and it lands in an HTML attribute.
    # A quote or an angle bracket that is not escaped would end the attribute
    # early and put upstream-controlled markup into the document head.
    test "escapes an upstream blurb that contains markup", %{conn: conn} do
      ingest(
        "sneaky",
        "1.0.0",
        %{"nerves_system_rpi4" => %{"status" => "pass"}},
        ~S|a "quoted" <script>alert(1)</script> blurb|
      )

      html = fetch(conn, "/packages/sneaky")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&quot;quoted&quot;"
      assert meta(html, "description") =~ "&lt;script&gt;"
    end

    # Google truncates around 155 characters. A description cut mid-word by the
    # search engine reads worse than one this page ended deliberately.
    test "truncates a long upstream blurb on a word boundary", %{conn: conn} do
      ingest(
        "verbose",
        "1.0.0",
        %{"nerves_system_rpi4" => %{"status" => "pass"}},
        String.duplicate("an extremely wordy upstream description ", 20)
      )

      description = meta(fetch(conn, "/packages/verbose"), "description")

      assert String.length(description) <= 158
      assert String.ends_with?(description, "...")
      refute description =~ ~r/\s\.\.\.$/
    end
  end
end
