defmodule PortalWeb.ApiSchemas.PackagesResponse do
  @moduledoc "The schema-v2 catalog document."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.Package

  OpenApiSpex.schema(
    %{
      title: "PackagesResponse",
      description: "Schema-v2 catalog document: the latest results of every package it holds.",
      type: :object,
      properties: %{
        schema: %Schema{type: :integer, enum: [2], description: "Schema version, `2`."},
        generated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When this document was generated."
        },
        packages: %Schema{
          type: :object,
          description: "Packages keyed by Hex package name.",
          additionalProperties: Package
        }
      },
      required: [:schema, :generated_at, :packages],
      additionalProperties: false
    },
    struct?: false
  )
end
