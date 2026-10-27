defmodule PortalWeb.ApiSchemas.SystemResult do
  @moduledoc "One system's result in a package's latest run."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.Status

  OpenApiSpex.schema(
    %{
      title: "SystemResult",
      description: "The result of one Nerves system (or assessment entry) in the latest run.",
      type: :object,
      properties: %{
        system_pkg: %Schema{
          type: :string,
          description:
            "The Nerves system package, or an assessment entry: `host`, `pure_elixir`, " <>
              "`registry_deps` or `nerves_tooling`."
        },
        system_version: %Schema{
          type: :string,
          nullable: true,
          description: "Version of the Nerves system; null for an assessment entry."
        },
        status: Status,
        firmware_size_bytes: %Schema{
          type: :integer,
          nullable: true,
          description: "Size of the firmware image, when one was built."
        },
        hex_version_tested: %Schema{
          type: :string,
          nullable: true,
          description: "The package version that was built."
        },
        run_id: %Schema{
          type: :string,
          nullable: true,
          description: "Identifier of the run this result belongs to."
        },
        log_path: %Schema{
          type: :string,
          nullable: true,
          description: "Relative path of the stored build log."
        }
      },
      required: [
        :system_pkg,
        :system_version,
        :status,
        :firmware_size_bytes,
        :hex_version_tested,
        :run_id,
        :log_path
      ],
      additionalProperties: false
    },
    struct?: false
  )
end
