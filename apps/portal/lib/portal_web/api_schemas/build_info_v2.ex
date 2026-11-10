defmodule PortalWeb.ApiSchemas.BuildInfoV2 do
  @moduledoc "What a format-2 build was built with."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{CompileEnvEntry, DeclaredDep, DepLockEntry}

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
        mix_target: %Schema{
          type: :string,
          description:
            "The `MIX_TARGET` the files were compiled under: the system's target name " <>
              "(`rpi4` for `nerves_system_rpi4`), or `host`."
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
        },
        config_variant: %Schema{
          type: :string,
          enum: Compatibility.ConfigVariants.names(),
          description:
            "Optional, informational: the named config variant a toolchain build was " <>
              "compiled in. Absent for the default build. A client matches a variant by " <>
              "its `compile_env` like any other build."
        },
        declared: %Schema{
          type: :array,
          items: DeclaredDep,
          description:
            "Optional: every dependency the package declares, optional ones included, " <>
              "from the build's lock. Absent for builds made before it was recorded."
        },
        manager: %Schema{
          type: :string,
          enum: ["mix", "rebar3", "make"],
          description:
            "Optional: the manager Mix built the package with, from the build's trace. A " <>
              "client skips a build whose manager differs from its own dependency's. Absent " <>
              "on builds made before it was recorded."
        }
      },
      required: [
        :elixir,
        :otp,
        :dep_env,
        :mix_target,
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
