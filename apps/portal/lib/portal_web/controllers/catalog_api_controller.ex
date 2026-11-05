defmodule PortalWeb.CatalogApiController do
  use PortalWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Portal.Catalog
  alias Portal.Catalog.TopFailing
  alias Portal.Precompiled.{Batches, ManifestRefs, Manifests, Root}
  alias PortalWeb.PrecompiledHTTP

  alias PortalWeb.ApiSchemas.{
    Error,
    FailingResponse,
    ManifestV1,
    ManifestV2,
    PackagesResponse,
    SignedEnvelope,
    StatsResponse
  }

  # Shared by the operation specs below, which are evaluated at compile time.
  @package_param [in: :path, type: :string, required: true, description: "Hex package name."]

  @etag_header %{
    "etag" => %OpenApiSpex.Header{
      description: "Identifies these exact bytes.",
      schema: %Schema{type: :string}
    }
  }

  @not_modified %OpenApiSpex.Response{
    description: "The `If-None-Match` tag names these bytes; no body.",
    headers: @etag_header
  }

  @badge_grey "#9ca3af"
  @badge_green "#22c55e"
  @badge_yellow "#eab308"

  operation :packages,
    tags: ["Catalog"],
    operation_id: "listPackages",
    summary: "Every package's latest results",
    description:
      "The schema-v2 catalog: every package with the per-system results of its latest run. " <>
        "Served from a cache refreshed at most once a minute.",
    responses: [ok: {"The catalog", "application/json", PackagesResponse}]

  def packages(conn, _params) do
    conn
    |> put_cache_headers()
    |> json(Catalog.latest_by_pkg_json())
  end

  operation :package,
    tags: ["Catalog"],
    operation_id: "getPackage",
    summary: "One package's latest results",
    description: "The schema-v2 catalog document holding only the named package.",
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Hex package name."]
    ],
    responses: [
      ok: {"The package", "application/json", PackagesResponse},
      not_found: {"No such package in the catalog", "application/json", Error}
    ]

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

  operation :stats,
    tags: ["Catalog"],
    operation_id: "getStats",
    summary: "Aggregate result counts",
    description: "Result counts per status, overall and per Nerves system.",
    responses: [ok: {"The statistics", "application/json", StatsResponse}]

  def stats(conn, _params) do
    conn
    |> put_cache_headers()
    |> json(Catalog.stats_json())
  end

  operation :failing,
    tags: ["Catalog"],
    operation_id: "listFailing",
    summary: "Failing packages ranked by downloads",
    description:
      "Packages whose latest run has at least one `fail` or `error` target, ranked by " <>
        "Hex.pm downloads. An invalid parameter falls back to its default rather than erroring.",
    parameters: [
      sort: [
        in: :query,
        schema: %Schema{type: :string, enum: ["recent", "all"], default: "recent"},
        description: "`recent`: 90-day downloads. `all`: all-time downloads."
      ],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
        description: "Number of packages. Out-of-range values are clamped."
      ],
      system: [
        in: :query,
        type: :string,
        description:
          "A Nerves system package name, e.g. `nerves_system_rpi4`: only packages failing on it."
      ]
    ],
    responses: [ok: {"The ranked packages", "application/json", FailingResponse}]

  def failing(conn, params) do
    opts = TopFailing.opts_from_params(params)

    conn
    |> put_cache_headers()
    |> json(%{
      schema: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      sort: Keyword.fetch!(opts, :sort),
      packages: TopFailing.list(opts)
    })
  end

  operation :precompiled_manifest,
    tags: ["Precompiled"],
    operation_id: "getManifestV1",
    summary: "Precompiled manifest, format 1",
    description:
      "Every published version and target of a package with its files. Kept for existing " <>
        "clients; new clients use format 2. Once a batch is signed, these are the exact bytes " <>
        "the newest batch names, with their SHA-256 as the `etag`.",
    parameters: [package: @package_param],
    responses: [
      ok: {"The manifest", "application/json", ManifestV1, headers: @etag_header},
      not_modified: @not_modified,
      not_found: {"The package has no precompiled files", "application/json", Error}
    ]

  def precompiled_manifest(conn, %{"package" => raw_package}) do
    serve_manifest(conn, raw_package, &Batches.manifests/1, &Catalog.precompiled_manifest/1)
  end

  operation :precompiled_manifest_v2,
    tags: ["Precompiled"],
    operation_id: "getManifestV2",
    summary: "Precompiled manifest, format 2",
    description:
      "A build list per version: one build per target and toolchain, including toolchain " <>
        "builds for projects that are not Nerves projects. Once a batch is signed, these are " <>
        "the exact bytes its `manifests_v2` names, with their SHA-256 as the `etag`.",
    parameters: [package: @package_param],
    responses: [
      ok: {"The manifest", "application/json", ManifestV2, headers: @etag_header},
      not_modified: @not_modified,
      not_found: {"The package has no build format 2 can publish", "application/json", Error}
    ]

  def precompiled_manifest_v2(conn, %{"package" => raw_package}) do
    serve_manifest(conn, raw_package, &Batches.manifests_v2/1, &Catalog.precompiled_manifest_v2/1)
  end

  # Per-name manifests change with every batch, so shared caches (a CDN) must
  # not store them: clients fetch by-sha manifests from content origins and
  # only these from the source.
  defp serve_manifest(conn, raw_package, batch_map, live) do
    package = String.replace_suffix(raw_package, ".json", "")

    case stored_manifest(package, batch_map) do
      {:ok, sha, bytes} ->
        PrecompiledHTTP.send_bytes(conn, bytes, PrecompiledHTTP.quote_sha(sha), :private_short)

      :none ->
        case live.(package) do
          nil ->
            conn
            |> PrecompiledHTTP.no_store()
            |> put_status(:not_found)
            |> json(%{error: "precompiled manifest not found"})

          manifest ->
            conn
            |> put_resp_header("cache-control", PrecompiledHTTP.cache_control(:private_short))
            |> json(manifest)
        end
    end
  end

  # The bytes the newest batch signed over, when a batch exists, from the map
  # of the format asked for (`Batches.manifests/1` or `Batches.manifests_v2/1`).
  # Before the first batch, or for a package the newest batch does not name,
  # the live render stands in, without an etag; a client that verifies
  # batches (elixir_precompiled) cannot use it, one that does not still can.
  defp stored_manifest(package, batch_map) do
    with %{} = batch <- Batches.latest(),
         sha when is_binary(sha) <- batch_map.(batch)[package],
         {:ok, bytes} <- Manifests.read(sha) do
      {:ok, sha, bytes}
    else
      _ -> :none
    end
  end

  @by_sha_param [
    in: :path,
    schema: %Schema{type: :string, pattern: "^[0-9a-f]{64}\\.json$"},
    required: true,
    description: "Lowercase hex SHA-256 of the manifest bytes, then `.json`."
  ]

  operation :precompiled_manifest_by_sha,
    tags: ["Precompiled"],
    operation_id: "getManifestV1BySha",
    summary: "Precompiled manifest, format 1, by SHA-256",
    description:
      "The format-1 manifest bytes a signed batch named with this SHA-256 in `manifests`. " <>
        "Content-addressed and immutable, so caches and content origins may keep it forever.",
    parameters: [sha: @by_sha_param],
    responses: [
      ok: {"The manifest", "application/json", ManifestV1, headers: @etag_header},
      not_modified: @not_modified,
      not_found:
        {"No batch named a format-1 manifest with this digest", "application/json", Error}
    ]

  def precompiled_manifest_by_sha(conn, %{"sha" => raw}), do: serve_by_sha(conn, raw, 1)

  operation :precompiled_manifest_v2_by_sha,
    tags: ["Precompiled"],
    operation_id: "getManifestV2BySha",
    summary: "Precompiled manifest, format 2, by SHA-256",
    description:
      "The format-2 manifest bytes a signed batch named with this SHA-256 in `manifests_v2`. " <>
        "Content-addressed and immutable, so caches and content origins may keep it forever.",
    parameters: [sha: @by_sha_param],
    responses: [
      ok: {"The manifest", "application/json", ManifestV2, headers: @etag_header},
      not_modified: @not_modified,
      not_found:
        {"No batch named a format-2 manifest with this digest", "application/json", Error}
    ]

  def precompiled_manifest_v2_by_sha(conn, %{"sha" => raw}), do: serve_by_sha(conn, raw, 2)

  # Only a sha some signed batch named in this format (`ManifestRefs`), and
  # only bytes that still hash to it: a CDN pins whatever this returns for a
  # year, and the store also holds file blobs that only `files/` may serve.
  # Every miss looks the same, so the route is no oracle for what the store holds.
  defp serve_by_sha(conn, raw, format) do
    with sha when is_binary(sha) <- by_sha_name(raw),
         true <- ManifestRefs.named?(sha, format),
         {:ok, bytes} <- Manifests.read_intact(sha) do
      PrecompiledHTTP.send_bytes(conn, bytes, PrecompiledHTTP.quote_sha(sha), :immutable)
    else
      _ ->
        conn
        |> PrecompiledHTTP.no_store()
        |> put_status(:not_found)
        |> json(%{error: "precompiled manifest not found"})
    end
  end

  # The digest is checked as 64 lowercase hex before anything looks it up.
  defp by_sha_name(raw) do
    sha = String.replace_suffix(raw, ".json", "")
    if sha != raw and Portal.ArtifactStore.valid_sha256?(sha), do: sha
  end

  operation :precompiled_root,
    tags: ["Precompiled"],
    operation_id: "getRoot",
    summary: "Signed root document",
    description:
      "Which keys may sign batches and roots, and the thresholds. The payload decodes to a " <>
        "`RootPayload`.",
    responses: [
      ok: {"The signed root", "application/json", SignedEnvelope, headers: @etag_header},
      not_modified: @not_modified,
      not_found: {"This deployment publishes no root document", "application/json", Error}
    ]

  def precompiled_root(conn, _params) do
    case Root.load() do
      {:ok, body} ->
        PrecompiledHTTP.send_bytes(conn, body, PrecompiledHTTP.etag(body), :revalidate)

      {:error, :no_root} ->
        conn
        |> PrecompiledHTTP.no_store()
        |> put_status(:not_found)
        |> json(%{error: "no root document"})
    end
  end

  operation :precompiled_batch,
    tags: ["Precompiled"],
    operation_id: "getLatestBatch",
    summary: "Newest signed batch",
    description:
      "The newest batch: the SHA-256 of every package's manifest bytes. The payload decodes " <>
        "to a `BatchPayload`. The `etag` is the SHA-256 of the envelope bytes; send it as " <>
        "`If-None-Match` to get a 304 while the batch is unchanged.",
    responses: [
      ok: {"The newest batch", "application/json", SignedEnvelope, headers: @etag_header},
      not_modified: @not_modified,
      service_unavailable: {"No batch has been signed yet", "application/json", Error}
    ]

  def precompiled_batch(conn, _params) do
    case Batches.latest() do
      nil ->
        conn
        |> PrecompiledHTTP.no_store()
        |> put_status(:service_unavailable)
        |> json(%{error: "no signed batch yet"})

      batch ->
        serve_batch(conn, batch)
    end
  end

  operation :precompiled_batch_history,
    tags: ["Precompiled"],
    operation_id: "getBatch",
    summary: "A past signed batch",
    description:
      "A batch by its sequence number, in the same envelope as the newest one: to audit " <>
        "history, or to re-verify a manifest fetched against an older batch.",
    parameters: [
      sequence: [
        in: :path,
        schema: %Schema{type: :integer, minimum: 1},
        required: true,
        description: "The batch's sequence number."
      ]
    ],
    responses: [
      ok: {"The batch", "application/json", SignedEnvelope, headers: @etag_header},
      not_modified: @not_modified,
      not_found: {"No batch with that sequence", "application/json", Error}
    ]

  def precompiled_batch_history(conn, %{"sequence" => raw}) do
    with {sequence, ""} <- raw |> String.replace_suffix(".json", "") |> Integer.parse(),
         %{} = batch <- Batches.get(sequence) do
      serve_batch(conn, batch)
    else
      _ ->
        conn
        |> PrecompiledHTTP.no_store()
        |> put_status(:not_found)
        |> json(%{error: "batch not found"})
    end
  end

  # The tag is the sha of the bytes served: a client that cached the envelope
  # gets a 304 for exactly as long as these bytes are the answer.
  defp serve_batch(conn, batch) do
    bytes = Batches.envelope(batch)
    PrecompiledHTTP.send_bytes(conn, bytes, PrecompiledHTTP.etag(bytes), :revalidate)
  end

  operation :precompiled_file,
    tags: ["Precompiled"],
    operation_id: "getFile",
    summary: "A precompiled file by SHA-256",
    description:
      "The bytes of a file a published manifest lists. Content-addressed: check them " <>
        "against the digest you asked for. Immutable: served with a one-year `cache-control` " <>
        "and its SHA-256 as the `etag`.",
    parameters: [
      sha256: [
        in: :path,
        schema: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"},
        required: true,
        description: "Lowercase hex SHA-256 of the file."
      ]
    ],
    responses: [
      ok:
        {"The file's bytes", "application/octet-stream", %Schema{type: :string, format: :binary}},
      not_modified: @not_modified,
      # `send_resp/3` with no content type: the body is the bare text below.
      not_found: %OpenApiSpex.Response{
        description: "No published file with that digest. The body is the text `Not Found`."
      }
    ]

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
      etag = PrecompiledHTTP.quote_sha(sha256)
      conn = PrecompiledHTTP.put_validators(conn, etag, :immutable)

      if PrecompiledHTTP.not_modified?(conn, etag) do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, Portal.ArtifactStore.blob_path(sha256))
      end
    else
      _ -> conn |> PrecompiledHTTP.no_store() |> send_resp(404, "Not Found")
    end
  end

  # An SVG for READMEs, outside `/api`.
  operation :badge, false

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
