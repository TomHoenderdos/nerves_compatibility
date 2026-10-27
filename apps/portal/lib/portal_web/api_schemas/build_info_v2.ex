defmodule PortalWeb.ApiSchemas.BuildInfoV2 do
  @moduledoc "What a format-2 build was built with."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{CompileEnvEntry, DepLockEntry}

  OpenApiSpex.schema(
    %{
      title: "BuildInfoV2",
      description:
        "The format-1 build fields plus `dep_env`. Format 2 lists only builds a client can " <>
          "match, so the toolchain, `deps`, `compile_env` and `package_checksum` are never null.",
      type: :object,
      properties: %{
        elixir: %Schema{type: :string, description: "Elixir version."},
        otp: %Schema{type: :string, description: "OTP major version."},
        dep_env: %Schema{
          type: :string,
          description: "The Mix env the package was compiled under as a dependency."
        },
        system_version: %Schema{
          type: :string,
          nullable: true,
          description: "Nerves system version; null for `pure_elixir`."
        },
        run_id: %Schema{type: :string, nullable: true},
        image_digest: %Schema{type: :string, nullable: true},
        deps: %Schema{
          type: :object,
          description: "The dependency tree the files were compiled against.",
          additionalProperties: DepLockEntry
        },
        compile_env: %Schema{type: :array, items: CompileEnvEntry},
        package_checksum: %Schema{
          type: :string,
          description: "The package's own outer Hex checksum."
        }
      },
      required: [
        :elixir,
        :otp,
        :dep_env,
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
