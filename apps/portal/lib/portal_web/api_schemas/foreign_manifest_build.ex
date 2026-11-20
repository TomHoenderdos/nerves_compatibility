defmodule PortalWeb.ApiSchemas.ForeignManifestBuild do
  @moduledoc "One build under a format-2 version's `foreign_priv` object."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{FileEntry, ForeignBuildInfoV2, ForeignFileEntry}

  OpenApiSpex.schema(
    %{
      title: "ForeignManifestBuild",
      description:
        "A `ManifestBuild` whose compile wrote files into another app's build `priv` " <>
          "(`foreign_priv`, with `build.foreign_priv_rule`), or a build of that app itself " <>
          "(`build.foreign_priv_target`, no `foreign_priv`).",
      type: :object,
      properties: %{
        target: %Schema{type: :string},
        ebin: %Schema{type: :array, items: FileEntry},
        priv: %Schema{type: :array, items: FileEntry},
        foreign_priv: %Schema{type: :array, items: ForeignFileEntry},
        build: ForeignBuildInfoV2
      },
      required: [:target, :ebin, :priv, :build],
      additionalProperties: false
    },
    struct?: false
  )
end
