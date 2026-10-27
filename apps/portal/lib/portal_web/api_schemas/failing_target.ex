defmodule PortalWeb.ApiSchemas.FailingTarget do
  @moduledoc "One failing target of a package's latest run."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "FailingTarget",
      type: :object,
      properties: %{
        system: %Schema{type: :string, description: "`<system_pkg>@<system_version>`."},
        status: %Schema{type: :string, enum: ["fail", "error"]},
        failure_category: %Schema{
          type: :string,
          nullable: true,
          description: "Classified cause of the failure, when one was recognised."
        }
      },
      required: [:system, :status, :failure_category],
      additionalProperties: false
    },
    struct?: false
  )
end
