defmodule PortalWeb.ApiSchemas.ManifestEntry do
  @moduledoc "The files of one version and target in a format-1 manifest."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.{BuildInfo, FileEntry}

  OpenApiSpex.schema(
    %{
      title: "ManifestEntry",
      type: :object,
      properties: %{
        ebin: %Schema{type: :array, items: FileEntry, description: "Compiled BEAM and app files."},
        priv: %Schema{type: :array, items: FileEntry, description: "Files under `priv/`."},
        build: BuildInfo
      },
      required: [:ebin, :priv, :build],
      additionalProperties: false
    },
    struct?: false
  )
end
