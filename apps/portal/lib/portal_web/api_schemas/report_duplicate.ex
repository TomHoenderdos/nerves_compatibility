defmodule PortalWeb.ApiSchemas.ReportDuplicate do
  @moduledoc "The answer to a report identical to one received in the last 24 hours (`200`)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ReportDuplicate",
      description:
        "The same report was already received within 24 hours; it is counted again, not " <>
          "stored again. No id is given: the id is what retracts a report, and someone else " <>
          "with an identical project may have sent the first one.",
      type: :object,
      additionalProperties: false,
      required: [:duplicate],
      properties: %{duplicate: %Schema{type: :boolean, enum: [true]}},
      example: %{"duplicate" => true}
    },
    struct?: false
  )
end
