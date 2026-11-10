defmodule PortalWeb.ApiSchemas.ReportCreated do
  @moduledoc "The answer to a newly stored report (`201`)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ReportCreated",
      description:
        "The report's id. Keep it to retract the report later: the id is all a retraction " <>
          "takes, so it is given only to the sender whose report created the row.",
      type: :object,
      additionalProperties: false,
      required: [:id],
      properties: %{id: %Schema{type: :string, format: :uuid}},
      example: %{"id" => "5b2c6f0e-8d1a-4c39-9a57-2f0f3f0f9b11"}
    },
    struct?: false
  )
end
