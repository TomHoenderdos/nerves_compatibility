defmodule PortalWeb.ApiSchemas.HexSearchResponse do
  @moduledoc "Hex.pm package name suggestions."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "HexSearchResponse",
      description: "Up to eight Hex.pm packages matching the query.",
      type: :object,
      properties: %{
        packages: %Schema{
          type: :array,
          maxItems: 8,
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{type: :string},
              description: %Schema{type: :string, description: "Empty when Hex.pm has none."},
              url: %Schema{type: :string, description: "The package's Hex.pm page."}
            },
            required: [:name, :description, :url],
            additionalProperties: false
          }
        }
      },
      required: [:packages],
      additionalProperties: false,
      example: %{
        "packages" => [
          %{
            "name" => "jason",
            "description" => "A blazing fast JSON parser and generator in pure Elixir.",
            "url" => "https://hex.pm/packages/jason"
          }
        ]
      }
    },
    struct?: false
  )
end
