defmodule PortalWeb.ApiSchemas.ReportRejected do
  @moduledoc "The body of a `422` to a report."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ReportRejected",
      description: "Why the report was refused, one entry per refused field.",
      type: :object,
      additionalProperties: false,
      required: [:error, :details],
      properties: %{
        error: %Schema{type: :string},
        details: %Schema{type: :array, items: %Schema{type: :string}}
      },
      example: %{
        "error" => "invalid report",
        "details" => ["os: os.family must be unix or win32"]
      }
    },
    struct?: false
  )
end
