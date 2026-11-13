defmodule PortalWeb.ApiSchemas.BuildInfoV2 do
  @moduledoc "What a format-2 build was built with."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{CompileEnvEntry, CompileInputItem, DeclaredDep, DepLockEntry}

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
        compile_inputs: %Schema{
          type: :array,
          items: CompileInputItem,
          description:
            "Optional: the compile-time inputs a client checks itself. Absent on builds " <>
              "made before they were recorded. A build with any item to check is listed " <>
              "under `builds_with_inputs`."
        },
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
        },
        native: %Schema{
          type: :boolean,
          description:
            "Optional: whether any `priv` file is ELF. Absent when unknown (builds made " <>
              "before it was recorded)."
        },
        portable: %Schema{
          type: :boolean,
          description:
            "Optional: false when an ELF file is neither a shared object nor an " <>
              "executable (a kernel module, an object file); such a build is used on its " <>
              "own system version only. Absent when unknown."
        },
        otp_full: %Schema{
          type: :string,
          description: "Optional: the system's full OTP version, such as `28.1.2`."
        },
        toolchain: %Schema{
          type: :object,
          description: "Optional: the Nerves toolchain the build's lock resolved.",
          properties: %{
            package: %Schema{type: :string},
            version: %Schema{type: :string}
          },
          required: [:package, :version],
          additionalProperties: false
        },
        elf: %Schema{
          type: :object,
          description:
            "Optional, native builds only: `needs` maps every library soname the ELF " <>
              "files need to the symbol versions they need from it.",
          properties: %{
            needs: %Schema{
              type: :object,
              additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
            }
          },
          required: [:needs],
          additionalProperties: false
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
