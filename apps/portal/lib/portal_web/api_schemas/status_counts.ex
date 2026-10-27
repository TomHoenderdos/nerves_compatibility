defmodule PortalWeb.ApiSchemas.StatusCounts do
  @moduledoc "Result counts per status."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @statuses [:pass, :fail, :error, :skipped, :unknown]

  OpenApiSpex.schema(
    %{
      title: "StatusCounts",
      description: "Number of results with each status.",
      type: :object,
      properties: Map.new(@statuses, &{&1, %Schema{type: :integer, minimum: 0}}),
      required: @statuses,
      additionalProperties: false
    },
    struct?: false
  )
end
