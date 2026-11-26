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
        defined_modules: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Optional (S10): the modules the build's compile defined outside its ebin, " <>
              "sorted. With the entry's `ebin` names, the package's exact module list. " <>
              "Absent when unknown."
        },
        package_checksum: %Schema{
          type: :string,
          description: "The package's own outer Hex checksum."
        },
        variant: %Schema{
          type: :string,
          enum: Enum.map(Compatibility.Worlds.variants(), &Atom.to_string/1) ++ ["pinned"],
          description:
            "Optional, informational: the world a build under `builds_closure` was made " <>
              "in, or `pinned` for a build of one closure from a project's lock. Absent " <>
              "on every other build. A client matches the build by its `deps`."
        },
        erl_compiler_options: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: Compatibility.DeterministicBeams.options()},
          description:
            "Only on a build under a version's `deterministic` key: the " <>
              "`ERL_COMPILER_OPTIONS` it was compiled with, `[\"deterministic\"]`. A client " <>
              "takes such a build only when its own project sets exactly that option."
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
        triple: %Schema{
          type: :string,
          enum: Compatibility.HostTriple.all(),
          description:
            "Host-native builds only: the glibc Linux triple the build is for, as " <>
              "`Compatibility.HostTriple` normalises `system_architecture`."
        },
        libc: %Schema{
          type: :string,
          enum: ["glibc"],
          description: "Host-native builds only: the C library the triple names."
        },
        nif_version: %Schema{
          type: :string,
          description:
            "Host-native builds only: the NIF version of the VM it was built on; a " <>
              "client takes it only when its own is no older."
        },
        origins: %Schema{
          type: :array,
          description:
            "Host-native builds only: each priv ELF file the package downloaded at " <>
              "compile time, with the upstream archive it is a member of and that " <>
              "archive's SHA-256 as the package's own checksum file lists it. Empty for a " <>
              "package that compiled its own.",
          items: %Schema{
            type: :object,
            properties: %{
              path: %Schema{type: :string},
              checksum_file: %Schema{type: :string},
              archive: %Schema{type: :string},
              archive_sha256: %Schema{type: :string}
            },
            required: [:path, :checksum_file, :archive, :archive_sha256],
            additionalProperties: false
          }
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
