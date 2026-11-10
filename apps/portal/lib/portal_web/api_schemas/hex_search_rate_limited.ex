defmodule PortalWeb.ApiSchemas.HexSearchRateLimited do
  @moduledoc "The JSON body of a rate-limited Hex.pm package search."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "HexSearchRateLimited",
      description:
        "Too many searches from this client, or from everyone together. The " <>
          "`retry-after` header says how many seconds to wait. `packages` is " <>
          "always empty, so a client reading only that field shows no suggestions.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "A short, human-readable reason."},
        packages: %Schema{type: :array, maxItems: 0, items: %Schema{type: :object}}
      },
      required: [:error, :packages],
      additionalProperties: false,
      example: %{"error" => "Too many requests. Try again in 42 seconds.", "packages" => []}
    },
    struct?: false
  )
end
