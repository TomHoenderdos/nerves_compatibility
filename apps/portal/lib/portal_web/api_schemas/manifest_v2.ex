defmodule PortalWeb.ApiSchemas.ManifestV2 do
  @moduledoc "Precompiled manifest, format 2."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{ForeignLists, ManifestBuild}

  OpenApiSpex.schema(
    %{
      title: "ManifestV2",
      description:
        "Format 2: a list of builds per version, one per target and toolchain. A client " <>
          "that gets a `format` it does not know must fail rather than guess.",
      type: :object,
      properties: %{
        format: %Schema{type: :integer, enum: [2]},
        versions: %Schema{
          type: :object,
          description: "Keyed by package version.",
          additionalProperties: %Schema{
            type: :object,
            properties: %{
              builds: %Schema{type: :array, items: ManifestBuild},
              builds_with_inputs: %Schema{
                type: :array,
                items: ManifestBuild,
                description:
                  "Builds whose `compile_inputs` a client must check. Clients before " <>
                    "0.6.0 do not read this key."
              },
              builds_closure: %Schema{
                type: :array,
                items: ManifestBuild,
                description:
                  "World builds: the package built with every optional dependency, at any " <>
                    "depth, that a common application shape (a world) has. Only clients " <>
                    "0.7.0 and later, which require a build's whole `deps` closure to equal " <>
                    "their env closure, read this key. Absent when empty."
              },
              builds_host_native: %Schema{
                type: :array,
                items: ManifestBuild,
                description:
                  "Host-native builds (`target: \"host_native\"`): a NIF package built for " <>
                    "one glibc Linux `triple`, beams and priv ELF files together. Only a " <>
                    "client whose project opted in (`host_native: true`) reads this key, " <>
                    "and only on a host of the same triple whose libraries define every " <>
                    "`elf.needs` version. Absent when empty or while the portal's " <>
                    "`host_native_enabled` setting is off."
              },
              foreign_priv: ForeignLists,
              deterministic: %Schema{
                type: :object,
                description:
                  "Deterministic siblings: the version's toolchain, pinned and firmware " <>
                    "target builds compiled again " <>
                    "with `ERL_COMPILER_OPTIONS=deterministic`, each with " <>
                    "`build.erl_compiler_options: [\"deterministic\"]`, in the same lists as " <>
                    "the version's own. Only a client whose project's `ERL_COMPILER_OPTIONS` " <>
                    "is exactly `deterministic` reads this key, in place of the version's " <>
                    "other lists; no other client ever does. Absent when the version has " <>
                    "none or while the portal's `deterministic_builds_enabled` setting is off.",
                properties: %{
                  builds: %Schema{type: :array, items: ManifestBuild},
                  builds_with_inputs: %Schema{type: :array, items: ManifestBuild},
                  builds_closure: %Schema{type: :array, items: ManifestBuild},
                  foreign_priv: ForeignLists
                },
                required: [:builds],
                additionalProperties: false
              }
            },
            required: [:builds],
            additionalProperties: false
          }
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the newest build listed finished."
        }
      },
      required: [:format, :versions, :updated_at],
      additionalProperties: false
    },
    struct?: false
  )
end
