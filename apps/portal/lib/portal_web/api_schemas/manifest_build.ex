defmodule PortalWeb.ApiSchemas.ManifestBuild do
  @moduledoc "One build in a format-2 manifest."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{BuildInfoV2, FileEntry}

  OpenApiSpex.schema(
    %{
      title: "ManifestBuild",
      type: :object,
      properties: %{
        target: %Schema{
          type: :string,
          description:
            "A Nerves system package, or `pure_elixir` for files that fit every target."
        },
        ebin: %Schema{type: :array, items: FileEntry},
        priv: %Schema{type: :array, items: FileEntry},
        build: BuildInfoV2
      },
      required: [:target, :ebin, :priv, :build],
      additionalProperties: false
    },
    struct?: false
  )
end
