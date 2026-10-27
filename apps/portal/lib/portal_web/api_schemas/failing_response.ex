defmodule PortalWeb.ApiSchemas.FailingResponse do
  @moduledoc "Failing packages ranked by Hex.pm downloads."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.FailingPackage

  OpenApiSpex.schema(
    %{
      title: "FailingResponse",
      description:
        "Packages whose latest run has a `fail` or `error` target, highest download " <>
          "count first. Versioned on its own: `schema` is `1`.",
      type: :object,
      properties: %{
        schema: %Schema{type: :integer, enum: [1]},
        generated_at: %Schema{type: :string, format: :"date-time"},
        sort: %Schema{
          type: :string,
          enum: ["recent", "all"],
          description: "The ranking applied."
        },
        packages: %Schema{type: :array, items: FailingPackage}
      },
      required: [:schema, :generated_at, :sort, :packages],
      additionalProperties: false
    },
    struct?: false
  )
end
