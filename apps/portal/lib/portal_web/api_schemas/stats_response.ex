defmodule PortalWeb.ApiSchemas.StatsResponse do
  @moduledoc "The schema-v2 statistics document."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.StatusCounts

  @statuses [:pass, :fail, :error, :skipped, :unknown]

  OpenApiSpex.schema(
    %{
      title: "StatsResponse",
      description:
        "Aggregate counts over every stored result, except results a partial rebuild " <>
          "carried from an earlier run.",
      type: :object,
      properties: %{
        schema: %Schema{type: :integer, enum: [2], description: "Schema version, `2`."},
        generated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When this document was generated."
        },
        counts: %Schema{
          type: :object,
          description: "Counts across every result, assessment entries included.",
          properties: Map.new([:total | @statuses], &{&1, %Schema{type: :integer, minimum: 0}}),
          required: [:total | @statuses],
          additionalProperties: false
        },
        by_system: %Schema{
          type: :object,
          description:
            "Counts per Nerves system, keyed by `<system_pkg>@<system_version>`. " <>
              "Assessment entries are not systems and are left out here.",
          additionalProperties: StatusCounts
        },
        last_run_finished_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the most recent run finished."
        }
      },
      required: [:schema, :generated_at, :counts, :by_system, :last_run_finished_at],
      additionalProperties: false
    },
    struct?: false
  )
end
