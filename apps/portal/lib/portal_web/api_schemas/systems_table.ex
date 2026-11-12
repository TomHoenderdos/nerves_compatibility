defmodule PortalWeb.ApiSchemas.SystemsTable do
  @moduledoc "The systems table a batch names (`systems.json`)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @release %Schema{
    type: :object,
    description: "One release of a Nerves system.",
    properties: %{
      toolchain: %Schema{
        type: :object,
        properties: %{
          package: %Schema{type: :string, nullable: true},
          version: %Schema{
            type: :string,
            nullable: true,
            description:
              "The toolchain version a build resolved; null when only the " <>
                "system's Hex requirement is known."
          },
          series: %Schema{
            type: :string,
            nullable: true,
            description:
              "`major.minor` of the toolchain, or of a `~> X.Y.Z` requirement; null when " <>
                "neither pins one."
          }
        },
        required: [:package, :version, :series],
        additionalProperties: false
      },
      otp: %Schema{type: :string, nullable: true, description: "Full OTP version."},
      libs: %Schema{
        type: :object,
        nullable: true,
        description:
          "Shared libraries in the release's root filesystem (`lib`, `usr/lib`), each with " <>
            "the symbol versions it defines: those published builds of the system need, and " <>
            "the toolchain's own. Null until the release's libraries were read.",
        additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
      }
    },
    required: [:toolchain, :otp, :libs],
    additionalProperties: false
  }

  OpenApiSpex.schema(
    %{
      title: "SystemsTable",
      description:
        "Per Nerves system and release: the toolchain, OTP and libraries a native build is " <>
          "matched against on a release other than its own. Canonical JSON (keys sorted, no " <>
          "whitespace); clients refuse a body over 4 MiB.",
      type: :object,
      properties: %{
        format: %Schema{type: :integer, enum: [1]},
        systems: %Schema{
          type: :object,
          description: "Keyed by system package, then by release version.",
          additionalProperties: %Schema{type: :object, additionalProperties: @release}
        }
      },
      required: [:format, :systems],
      additionalProperties: false
    },
    struct?: false
  )
end
