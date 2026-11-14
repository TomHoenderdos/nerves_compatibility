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
            properties: %{
              builds: %Schema{type: :array, items: ManifestBuild},
              builds_with_inputs: %Schema{
                type: :array,
                items: ManifestBuild,
                description:
                  "Builds whose `compile_inputs` a client must check. Clients before " <>
                    "0.6.0 do not read this key."
              },
              builds_closure: %Schema{
                type: :array,
                items: ManifestBuild,
                description:
                  "World builds: the package built with every optional dependency, at any " <>
                    "depth, that a common application shape (a world) has. Only clients " <>
                    "0.7.0 and later, which require a build's whole `deps` closure to equal " <>
                    "their env closure, read this key. Absent when empty."
              }
            },
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
