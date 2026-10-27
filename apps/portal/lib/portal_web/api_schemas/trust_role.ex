defmodule PortalWeb.ApiSchemas.TrustRole do
  @moduledoc "Which keys may sign a role's documents."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "TrustRole",
      type: :object,
      properties: %{
        keyids: %Schema{type: :array, items: %Schema{type: :string}},
        threshold: %Schema{
          type: :integer,
          minimum: 1,
          description: "Valid signatures required."
        }
      },
      required: [:keyids, :threshold]
    },
    struct?: false
  )
end
