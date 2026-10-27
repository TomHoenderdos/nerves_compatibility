defmodule PortalWeb.ApiSchemas.ManifestV1 do
  @moduledoc "Precompiled manifest, format 1."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.ManifestEntry

  OpenApiSpex.schema(
    %{
      title: "ManifestV1",
      description:
        "Format 1: one entry per version and target. Kept for existing clients; new " <>
          "clients use format 2.",
      type: :object,
      properties: %{
        versions: %Schema{
          type: :object,
          description:
            "Keyed by package version, then by target: a Nerves system package, or " <>
              "`pure_elixir` for files that fit every target.",
          additionalProperties: %Schema{type: :object, additionalProperties: ManifestEntry}
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the newest build represented here finished."
        }
      },
      required: [:versions, :updated_at],
      additionalProperties: false
    },
    struct?: false
  )
end
