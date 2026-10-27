defmodule PortalWeb.ApiSchemas.RootPayload do
  @moduledoc "The decoded payload of `root.json`."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.TrustRole

  OpenApiSpex.schema(
    %{
      title: "RootPayload",
      description: "The decoded `payload` of `root.json`: the keys that may sign, per role.",
      type: :object,
      properties: %{
        version: %Schema{type: :integer},
        expires: %Schema{type: :string, format: :"date-time"},
        keys: %Schema{
          type: :object,
          description: "Public keys keyed by key id.",
          additionalProperties: %Schema{
            type: :object,
            properties: %{
              type: %Schema{type: :string, enum: ["ed25519"]},
              public: %Schema{type: :string, description: "Public key bytes, base64url."}
            },
            required: [:type, :public]
          }
        },
        roles: %Schema{
          type: :object,
          properties: %{root: TrustRole, batch: TrustRole},
          required: [:root, :batch]
        }
      },
      required: [:version, :expires, :keys, :roles]
    },
    struct?: false
  )
end
