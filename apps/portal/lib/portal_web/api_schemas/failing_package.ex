defmodule PortalWeb.ApiSchemas.FailingPackage do
  @moduledoc "A package whose latest run fails on at least one target."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.FailingTarget

  OpenApiSpex.schema(
    %{
      title: "FailingPackage",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Hex package name."},
        description: %Schema{type: :string, nullable: true},
        latest_version: %Schema{
          type: :string,
          nullable: true,
          description: "Latest version on Hex.pm."
        },
        version_tested: %Schema{
          type: :string,
          nullable: true,
          description: "The version the latest run built."
        },
        last_run_at: %Schema{type: :string, format: :"date-time", nullable: true},
        downloads_recent: %Schema{
          type: :integer,
          nullable: true,
          description: "Hex.pm downloads over the last 90 days."
        },
        downloads_all: %Schema{
          type: :integer,
          nullable: true,
          description: "All-time Hex.pm downloads."
        },
        status: %Schema{
          type: :string,
          enum: ["fail", "error"],
          description: "`error` if any failing target errored, otherwise `fail`."
        },
        failing_targets: %Schema{
          type: :array,
          items: FailingTarget,
          description: "Only the `fail` and `error` targets of the latest run."
        },
        failing_count: %Schema{type: :integer, minimum: 1},
        total_targets: %Schema{type: :integer, minimum: 1}
      },
      required: [
        :name,
        :description,
        :latest_version,
        :version_tested,
        :last_run_at,
        :downloads_recent,
        :downloads_all,
        :status,
        :failing_targets,
        :failing_count,
        :total_targets
      ],
      additionalProperties: false
    },
    struct?: false
  )
end
