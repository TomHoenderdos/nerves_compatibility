defmodule PortalWeb.CatalogApiController do
  use PortalWeb, :controller

  alias Portal.Catalog
  alias Portal.Catalog.HotTickets
  alias Portal.Precompiled.{Batches, Manifests, Root}

  @badge_grey "#9ca3af"
  @badge_green "#22c55e"
  @badge_yellow "#eab308"

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

  def failing(conn, params) do
    opts = HotTickets.opts_from_params(params)

    conn
    |> put_cache_headers()
    |> json(%{
      schema: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      sort: Keyword.fetch!(opts, :sort),
      packages: HotTickets.list(opts)
    })
  end

  def precompiled_manifest(conn, %{"package" => raw_package}) do
    serve_manifest(conn, raw_package, &Batches.manifests/1, &Catalog.precompiled_manifest/1)
  end

  def precompiled_manifest_v2(conn, %{"package" => raw_package}) do
    serve_manifest(conn, raw_package, &Batches.manifests_v2/1, &Catalog.precompiled_manifest_v2/1)
  end

  defp serve_manifest(conn, raw_package, batch_map, live) do
    package = String.replace_suffix(raw_package, ".json", "")

    case stored_manifest(package, batch_map) do
      {:ok, sha, bytes} ->
        conn
        |> put_cache_headers()
        |> put_resp_header("etag", ~s("#{sha}"))
        |> send_json_bytes(bytes)

      :none ->
        case live.(package) do
          nil ->
            conn |> put_status(:not_found) |> json(%{error: "precompiled manifest not found"})

          manifest ->
            conn |> put_cache_headers() |> json(manifest)
        end
    end
  end

  # The bytes the newest batch signed over, when a batch exists, from the map
  # of the format asked for (`Batches.manifests/1` or `Batches.manifests_v2/1`).
  # Before the first batch the live render stands in; a client that verifies
  # batches cannot use it, one that does not (today's script) still can.
  defp stored_manifest(package, batch_map) do
    with %{} = batch <- Batches.latest(),
         sha when is_binary(sha) <- batch_map.(batch)[package],
         {:ok, bytes} <- Manifests.read(sha) do
      {:ok, sha, bytes}
    else
      _ -> :none
    end
  end

  def precompiled_root(conn, _params) do
    case Root.load() do
      {:ok, body} ->
        sha = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

        conn
        |> put_cache_headers()
        |> put_resp_header("etag", ~s("#{sha}"))
        |> send_json_bytes(body)

      {:error, :no_root} ->
        conn |> put_status(:not_found) |> json(%{error: "no root document"})
    end
  end

  def precompiled_batch(conn, _params) do
    case Batches.latest() do
      nil -> conn |> put_status(:service_unavailable) |> json(%{error: "no signed batch yet"})
      batch -> serve_batch(conn, batch)
    end
  end

  def precompiled_batch_history(conn, %{"sequence" => raw}) do
    with {sequence, ""} <- raw |> String.replace_suffix(".json", "") |> Integer.parse(),
         %{} = batch <- Batches.get(sequence) do
      serve_batch(conn, batch)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "batch not found"})
    end
  end

  defp serve_batch(conn, batch) do
    conn
    |> put_cache_headers()
    |> put_resp_header("etag", ~s("batch-#{batch.sequence}"))
    |> send_json_bytes(Batches.envelope(batch))
  end

  defp send_json_bytes(conn, bytes) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, bytes)
  end

  # The request supplies only a validated digest; the path is derived from the
  # configured blob store, never taken from request params or stored disk_path.
  # `present?/1` also rejects a symlink before serving a worker-produced
  # artifact, and is the same check the manifest applies to every file it lists.
  # `published_sha256?/1` is the manifests' publication gate: a blob only a
  # non-publishing or revoked remote builder uploaded is stored but not served.
  # sobelow_skip ["Traversal.SendFile"]
  def precompiled_file(conn, %{"sha256" => sha256}) do
    with true <- Portal.ArtifactStore.valid_sha256?(sha256),
         true <- Catalog.published_sha256?(sha256),
         true <- Portal.ArtifactStore.present?(sha256) do
      path = Portal.ArtifactStore.blob_path(sha256)

      conn
      |> put_cache_headers()
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  def badge(conn, %{"name" => raw_name}) do
    name = String.replace_suffix(raw_name, ".svg", "")

    case Catalog.latest_system_results(name) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_resp_content_type("image/svg+xml")
        |> send_resp(404, svg(name, "unknown", @badge_grey))

      results ->
        {status, color} = badge_status(results)

        conn
        |> put_badge_cache_headers()
        |> put_resp_content_type("image/svg+xml")
        |> send_resp(200, svg(name, status, color))
    end
  end

  defp put_cache_headers(conn) do
    put_resp_header(conn, "cache-control", "public, max-age=60")
  end

  # The badge is the one endpoint meant to be embedded in someone else's
  # README, so it is fetched by every reader of that page rather than by a
  # client polling for fresh data. A minute of caching is pointless there: a
  # package's status changes when it is rebuilt, which is days apart, and
  # GitHub proxies badges through camo anyway.
  #
  # `stale-while-revalidate` is what keeps the badge from ever being the slow
  # part of someone's README -- past the hour a cache serves the old SVG
  # immediately and refreshes behind the request.
  defp put_badge_cache_headers(conn) do
    put_resp_header(conn, "cache-control", "public, max-age=3600, stale-while-revalidate=86400")
  end

  # Wording from issue #41: "nerves: passing" left readers guessing what had
  # passed. "compatible" and "compatibility issues" say what was checked; the
  # per-target breakdown is one click away on the package page.
  #
  # Only a fully clean run is "compatible". A partial pass is still an issue
  # worth surfacing, even when the unfinished targets were skipped rather than
  # failed. A run that skipped everything (Nerves tooling, retired releases,
  # gleam) checked nothing, so it says so instead of claiming either verdict.
  defp badge_status([]), do: {"unknown", @badge_grey}

  defp badge_status(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == :pass)) -> {"compatible", @badge_green}
      Enum.all?(statuses, &(&1 == :skipped)) -> {"not checked", @badge_grey}
      true -> {"compatibility issues", @badge_yellow}
    end
  end

  defp svg(package_name, status, color) do
    package_name = package_name |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
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
