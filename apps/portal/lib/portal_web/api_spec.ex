defmodule PortalWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document for the public JSON API, served at `/api/openapi.json`
  and rendered for people at `/api/docs`.

  Built from the router and the `operation` specs on the controllers, so a
  route and its documentation cannot drift apart. Only the routes
  `documented_routes/0` returns are asked for an operation: the router also
  holds HTML pages, the builder API, admin and auth endpoints, none of which
  belong here, and the controllers behind some of them (`PageController`)
  serve one documented action next to many undocumented ones.

  Response shapes live in `PortalWeb.ApiSchemas.*`; the controller tests
  assert every response against them.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{ExternalDocumentation, Info, OpenApi, Paths, Tag}

  # Routes under /api that describe the API rather than being part of it.
  @self_paths ["/api/docs", "/api/openapi.json"]

  # Path parameters the controller accepts with or without a `.json` suffix.
  # The suffixed form is the one the documentation and clients use, so the
  # spec names that path, and the parameter is the bare value.
  @json_suffixed %{
    "/api/precompiled/manifests/{package}" => "/api/precompiled/manifests/{package}.json",
    "/api/precompiled/v2/manifests/{package}" => "/api/precompiled/v2/manifests/{package}.json",
    "/api/precompiled/batches/{sequence}" => "/api/precompiled/batches/{sequence}.json"
  }

  # Schemas of documents carried inside a response rather than being one: the
  # decoded payloads of the signed envelopes. No operation references them, so
  # they are added to the components explicitly.
  @payload_schemas [PortalWeb.ApiSchemas.RootPayload, PortalWeb.ApiSchemas.BatchPayload]

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Nerves Compatibility API",
        version: "2",
        description: """
        Read-only JSON API of the Nerves Compatibility Tracker: the latest build \
        result of every package on every Nerves system, aggregate statistics, the \
        most-downloaded failing packages, and the precompiled package files \
        published from passing builds.

        No authentication. Responses are cacheable for a minute \
        (`cache-control: public, max-age=60`). Send `accept: application/json` or \
        no `accept` header.
        """
      },
      externalDocs: %ExternalDocumentation{
        description: "Precompiled package API: matching rules, signing and verification",
        url: precompiled_docs_url()
      },
      tags: [
        %Tag{
          name: "Catalog",
          description: "Build results per package and system, and aggregate statistics."
        },
        %Tag{
          name: "Precompiled",
          description:
            "Manifests of precompiled package files, the files themselves, and the signed " <>
              "documents a client verifies them against.",
          externalDocs: %ExternalDocumentation{
            description: "Format semantics and the trust chain",
            url: precompiled_docs_url()
          }
        }
      ],
      paths: paths()
    }
    |> OpenApiSpex.resolve_schema_modules()
    |> OpenApiSpex.add_schemas(@payload_schemas)
  end

  @doc "Where the precompiled format semantics are documented."
  def precompiled_docs_url, do: repo_url() <> "/blob/main/PRECOMPILED_API.md"

  @doc "Where the catalog document format is documented."
  def catalog_docs_url, do: repo_url() <> "/blob/main/docs/INDEX_FORMAT.md"

  # The repository is the one the configured issue tracker belongs to, so a
  # fork's docs link to its own copy of the format documents (and
  # `PortalWeb.IssueLinkTest` keeps repository URLs out of the source).
  defp repo_url do
    :portal
    |> Application.fetch_env!(:issues_url)
    |> String.replace(~r{/issues(/new)?/?$}, "")
  end

  @doc "Titles of the schemas carried inside responses (see `@payload_schemas`)."
  def payload_schema_titles, do: Enum.map(@payload_schemas, & &1.schema().title)

  @doc """
  The router's `/api` routes that make up the public JSON API: everything
  under `/api/` except the spec and its docs page.
  """
  def documented_routes do
    Enum.filter(PortalWeb.Router.__routes__(), &documented_route?/1)
  end

  @doc "The OpenAPI path a router path is documented under."
  def open_api_path(router_path) do
    path =
      router_path
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":" <> segment -> "{#{segment}}"
        segment -> segment
      end)

    Map.get(@json_suffixed, path, path)
  end

  defp documented_route?(%{path: "/api/" <> _ = path}), do: path not in @self_paths
  defp documented_route?(_route), do: false

  defp paths do
    documented_routes()
    |> Paths.from_routes()
    |> Map.new(fn {path, item} -> {Map.get(@json_suffixed, path, path), item} end)
  end
end
