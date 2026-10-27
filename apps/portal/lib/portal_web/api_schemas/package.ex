defmodule PortalWeb.ApiSchemas.Package do
  @moduledoc "One package in the schema-v2 catalog."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{NativeComponents, SystemResult}

  OpenApiSpex.schema(
    %{
      title: "Package",
      description: "A package and the per-system results of its latest run.",
      type: :object,
      properties: %{
        description: %Schema{type: :string, nullable: true, description: "From Hex.pm."},
        latest_version: %Schema{
          type: :string,
          nullable: true,
          description: "Latest version on Hex.pm."
        },
        last_run_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the package was last built."
        },
        native_components: NativeComponents,
        systems: %Schema{
          type: :object,
          description:
            "Results of the latest run, keyed by `<system_pkg>@<system_version>`. A partial " <>
              "rebuild carries the systems it left out from the previous run of the same version.",
          additionalProperties: SystemResult
        }
      },
      required: [:description, :latest_version, :last_run_at, :native_components, :systems],
      additionalProperties: false
    },
    struct?: false
  )
end
