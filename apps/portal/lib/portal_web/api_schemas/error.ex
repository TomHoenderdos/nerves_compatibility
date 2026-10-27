defmodule PortalWeb.ApiSchemas.Error do
  @moduledoc "The JSON body of a `404` or `503` from the JSON API."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "Error",
      description: "Why the request could not be answered.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "A short, human-readable reason."}
      },
      required: [:error],
      additionalProperties: false,
      example: %{"error" => "package not found"}
    },
    struct?: false
  )
end
