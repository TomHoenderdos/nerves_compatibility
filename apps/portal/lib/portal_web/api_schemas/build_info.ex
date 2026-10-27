defmodule PortalWeb.ApiSchemas.BuildInfo do
  @moduledoc "What a format-1 manifest entry was built with."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{CompileEnvEntry, DepLockEntry}

  OpenApiSpex.schema(
    %{
      title: "BuildInfo",
      description:
        "What the files were built with. A client uses an entry only when these match its " <>
          "own project; the matching rules are in the precompiled API document.",
      type: :object,
      properties: %{
        elixir: %Schema{type: :string, nullable: true, description: "Elixir version."},
        otp: %Schema{type: :string, nullable: true, description: "OTP major version."},
        system_version: %Schema{
          type: :string,
          nullable: true,
          description: "Nerves system version; null for `pure_elixir`."
        },
        run_id: %Schema{type: :string, nullable: true},
        image_digest: %Schema{type: :string, nullable: true},
        deps: %Schema{
          type: :object,
          nullable: true,
          description:
            "The dependency tree the files were compiled against, keyed by package name. " <>
              "Null for builds from before it was recorded.",
          additionalProperties: DepLockEntry
        },
        compile_env: %Schema{
          type: :array,
          nullable: true,
          items: CompileEnvEntry,
          description: "Null when it was not recorded."
        },
        package_checksum: %Schema{
          type: :string,
          nullable: true,
          description: "The package's own outer Hex checksum."
        }
      },
      required: [
        :elixir,
        :otp,
        :system_version,
        :run_id,
        :image_digest,
        :deps,
        :compile_env,
        :package_checksum
      ],
      additionalProperties: false
    },
    struct?: false
  )
end
