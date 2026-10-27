defmodule PortalWeb.ApiSchemas.BatchPayload do
  @moduledoc "The decoded payload of a batch."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "BatchPayload",
      description:
        "The decoded `payload` of a batch: the SHA-256 of every package's manifest bytes.",
      type: :object,
      properties: %{
        version: %Schema{type: :integer, description: "Batch format, `1`."},
        sequence: %Schema{
          type: :integer,
          minimum: 1,
          description: "Increases by one with every batch."
        },
        issued: %Schema{type: :string, format: :"date-time"},
        expires: %Schema{type: :string, format: :"date-time"},
        manifests: %Schema{
          type: :object,
          description: "Format-1 manifest SHA-256 keyed by package name.",
          additionalProperties: %Schema{type: :string}
        },
        manifests_v2: %Schema{
          type: :object,
          description:
            "Format-2 manifest SHA-256 keyed by package name. Absent from batches signed " <>
              "before format 2.",
          additionalProperties: %Schema{type: :string}
        }
      },
      required: [:version, :sequence, :issued, :expires, :manifests]
    },
    struct?: false
  )
end
