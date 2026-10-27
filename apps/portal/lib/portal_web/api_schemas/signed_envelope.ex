defmodule PortalWeb.ApiSchemas.SignedEnvelope do
  @moduledoc "A signed trust document."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "SignedEnvelope",
      description:
        "A signed document. Verify the Ed25519 signatures over the raw payload bytes " <>
          "before decoding them.",
      type: :object,
      properties: %{
        payload: %Schema{
          type: :string,
          description: "The signed JSON document, base64url without padding."
        },
        signatures: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              keyid: %Schema{
                type: :string,
                description: "Lowercase hex SHA-256 of the signing key's public bytes."
              },
              sig: %Schema{type: :string, description: "Ed25519 signature, base64url."}
            },
            required: [:keyid, :sig],
            additionalProperties: false
          }
        }
      },
      required: [:payload, :signatures],
      additionalProperties: false
    },
    struct?: false
  )
end
