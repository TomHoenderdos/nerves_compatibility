defmodule PortalWeb.ApiDocsController do
  @moduledoc """
  `/api/docs`: the OpenAPI document (`PortalWeb.ApiSpec`) rendered as a page
  in the site layout. Server-rendered from the same spec `/api/openapi.json`
  serves, so the two cannot disagree; no JavaScript.
  """

  use PortalWeb, :controller

  alias OpenApiSpex.Plug.PutApiSpec
  alias PortalWeb.{ApiDocs, ApiSpec}

  # Shares `PutApiSpec`'s cache with `/api/openapi.json`, so the spec is
  # built once per release rather than once per request.
  plug PutApiSpec, module: ApiSpec

  def index(conn, _params) do
    {spec, _operations} = PutApiSpec.get_spec_and_operation_lookup(conn)

    render(conn, :index,
      page_title: "API",
      page_description:
        "The public JSON API: build results per package and Nerves system, statistics, " <>
          "and precompiled package files.",
      current_user: PortalWeb.UserAuth.current_user(conn),
      info: spec.info,
      sections: ApiDocs.sections(spec),
      payloads: Enum.map(ApiSpec.payload_schema_titles(), &ApiDocs.schema_doc(spec, &1)),
      precompiled_docs_url: ApiSpec.precompiled_docs_url(),
      catalog_docs_url: ApiSpec.catalog_docs_url()
    )
  end
end
