defmodule PortalWeb.CatalogApiController do
  use PortalWeb, :controller

  alias Portal.Catalog

  def packages(conn, _params) do
    conn
    |> put_cache_headers()
    |> json(Catalog.latest_by_pkg_json())
  end

  def package(conn, %{"name" => name}) do
    case Catalog.latest_by_pkg_json(name) do
      %{packages: packages} = body when map_size(packages) > 0 ->
        conn
        |> put_cache_headers()
        |> json(body)

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "package not found"})
    end
  end

  def stats(conn, _params) do
    conn
    |> put_cache_headers()
    |> json(Catalog.stats_json())
  end

  def precompiled_manifest(conn, %{"package" => raw_package}) do
    package = String.replace_suffix(raw_package, ".json", "")

    case Catalog.precompiled_manifest(package) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "precompiled manifest not found"})

      manifest ->
        conn
        |> put_cache_headers()
        |> json(manifest)
    end
  end

  def precompiled_file(conn, %{"sha256" => sha256}) do
    case Catalog.artifact_by_sha256(sha256) do
      nil ->
        send_resp(conn, 404, "Not Found")

      artifact ->
        if File.regular?(artifact.disk_path) do
          conn
          |> put_cache_headers()
          |> put_resp_content_type("application/octet-stream")
          |> send_file(200, artifact.disk_path)
        else
          send_resp(conn, 404, "Not Found")
        end
    end
  end

  def badge(conn, %{"name" => raw_name}) do
    name = String.replace_suffix(raw_name, ".svg", "")

    case Catalog.latest_system_results(name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_resp_content_type("image/svg+xml")
        |> send_resp(404, svg(name, "unknown", "#9ca3af"))

      results ->
        {status, color} = badge_status(results)

        conn
        |> put_cache_headers()
        |> put_resp_content_type("image/svg+xml")
        |> send_resp(200, svg(name, status, color))
    end
  end

  defp put_cache_headers(conn) do
    put_resp_header(conn, "cache-control", "public, max-age=60")
  end

  defp badge_status([]), do: {"unknown", "#9ca3af"}

  defp badge_status(results) do
    total = length(results)
    pass_count = Enum.count(results, &(&1.status == :pass))
    fail_count = Enum.count(results, &(&1.status == :fail))
    error_count = Enum.count(results, &(&1.status == :error))

    cond do
      pass_count == total -> {"passing", "#22c55e"}
      fail_count > 0 or error_count > 0 -> {"#{pass_count}/#{total} passing", "#f97316"}
      true -> {"#{pass_count}/#{total} passing", "#eab308"}
    end
  end

  defp svg(package_name, status, color) do
    label = "nerves"
    label_width = String.length(label) * 6 + 10
    status_width = String.length(status) * 6 + 10
    total_width = label_width + status_width

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{total_width}" height="20" role="img" aria-label="#{label}: #{status}">
      <title>#{package_name} Nerves compatibility: #{status}</title>
      <linearGradient id="s" x2="0" y2="100%">
        <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
        <stop offset="1" stop-opacity=".1"/>
      </linearGradient>
      <clipPath id="r">
        <rect width="#{total_width}" height="20" rx="3" fill="#fff"/>
      </clipPath>
      <g clip-path="url(#r)">
        <rect width="#{label_width}" height="20" fill="#555"/>
        <rect x="#{label_width}" width="#{status_width}" height="20" fill="#{color}"/>
        <rect width="#{total_width}" height="20" fill="url(#s)"/>
      </g>
      <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
        <text aria-hidden="true" x="#{label_width / 2 * 10}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="#{(label_width - 10) * 10}">#{label}</text>
        <text x="#{label_width / 2 * 10}" y="140" transform="scale(.1)" fill="#fff" textLength="#{(label_width - 10) * 10}">#{label}</text>
        <text aria-hidden="true" x="#{(label_width + status_width / 2) * 10}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="#{(status_width - 10) * 10}">#{status}</text>
        <text x="#{(label_width + status_width / 2) * 10}" y="140" transform="scale(.1)" fill="#fff" textLength="#{(status_width - 10) * 10}">#{status}</text>
      </g>
    </svg>
    """
  end
end
