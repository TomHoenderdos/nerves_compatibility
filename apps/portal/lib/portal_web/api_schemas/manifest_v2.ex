defmodule PortalWeb.ApiSchemas.ManifestV2 do
  @moduledoc "Precompiled manifest, format 2."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.ManifestBuild

  OpenApiSpex.schema(
    %{
      title: "ManifestV2",
      description:
        "Format 2: a list of builds per version, one per target and toolchain. A client " <>
          "that gets a `format` it does not know must fail rather than guess.",
      type: :object,
      properties: %{
        format: %Schema{type: :integer, enum: [2]},
        versions: %Schema{
          type: :object,
          description: "Keyed by package version.",
          additionalProperties: %Schema{
            type: :object,
            properties: %{builds: %Schema{type: :array, items: ManifestBuild}},
            required: [:builds],
            additionalProperties: false
          }
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the newest build listed finished."
        }
      },
      required: [:format, :versions, :updated_at],
      additionalProperties: false
    },
    struct?: false
  )
end
