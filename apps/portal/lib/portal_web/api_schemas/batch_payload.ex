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
        },
        content: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uri},
          description:
            "Content origins (https) that also serve `files/` and the by-sha manifest " <>
              "paths. Absent when none are configured; clients then use the source only."
        },
        systems: %Schema{
          type: :string,
          pattern: "^[0-9a-f]{64}$",
          description:
            "SHA-256 of the systems table bytes (`/systems/by-sha/<sha>.json`). Absent " <>
              "while the table is empty."
        },
        release_index: %Schema{
          type: :object,
          description:
            "S10 round 5: the module index per release, for client 0.10's declared probe " <>
              "items. `shards`: 256 shards (`00` to `ff`, the first byte of the SHA-256 of " <>
              "a package name) of the read releases; `modules`: each probed module's definer " <>
              "set. Each value is the SHA-256 of a document at " <>
              "`/release-index/by-sha/<sha>.json`. Absent before any release was read.",
          properties: %{
            format: %Schema{type: :integer, enum: [1]},
            shards: %Schema{
              type: :object,
              additionalProperties: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"}
            },
            modules: %Schema{
              type: :object,
              additionalProperties: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"}
            }
          },
          required: [:format, :shards, :modules],
          additionalProperties: false
        }
      },
      required: [:version, :sequence, :issued, :expires, :manifests]
    },
    struct?: false
  )
end
