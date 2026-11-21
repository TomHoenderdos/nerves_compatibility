defmodule PortalWeb.ApiSchemas.RelocatedManifestBuild do
  @moduledoc "One build under a format-2 version's `relocated` object."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{BuildInfoV2, FileEntry, Relocation}

  OpenApiSpex.schema(
    %{
      title: "RelocatedManifestBuild",
      description:
        "A `ManifestBuild` whose beams `relocation` names are rewritten at install; their " <>
          "`sha256` is the served bytes'.",
      type: :object,
      properties: %{
        target: %Schema{type: :string},
        ebin: %Schema{type: :array, items: FileEntry},
        priv: %Schema{type: :array, items: FileEntry},
        relocation: Relocation,
        build: BuildInfoV2
      },
      required: [:target, :ebin, :priv, :relocation, :build],
      additionalProperties: false
    },
    struct?: false
  )
end
