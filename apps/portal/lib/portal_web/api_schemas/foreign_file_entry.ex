defmodule PortalWeb.ApiSchemas.ForeignFileEntry do
  @moduledoc "One foreign priv file a format-2 foreign build lists."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "ForeignFileEntry",
      description:
        "A Kino.JS asset archive the build's compile wrote into another app's build " <>
          "`priv`, fetched from `/api/precompiled/files/{sha256}` and installed at `path` " <>
          "under that app's build dir.",
      type: :object,
      properties: %{
        app: %Schema{
          type: :string,
          enum: [Compatibility.ForeignPriv.target()],
          description: "The app whose build `priv` the file goes into."
        },
        path: %Schema{
          type: :string,
          pattern: "^priv/assets/[A-Z][A-Za-z0-9_]*/[a-z2-7]{26}\\.tar\\.gz$",
          description:
            "Relative to that app's build dir: `priv/assets/<module dir>/<hash>.tar.gz`.",
          example: "priv/assets/Kino_VegaLite/uxwh53kfq2wszgf23hqwgkuiza.tar.gz"
        },
        sha256: %Schema{
          type: :string,
          pattern: "^[0-9a-f]{64}$",
          description: "Lowercase hex SHA-256 of the file's bytes."
        },
        size: %Schema{type: :integer, minimum: 0, description: "Size in bytes."},
        mode: %Schema{
          type: :integer,
          enum: [Compatibility.ForeignPriv.mode()],
          description: "`33188` (0o100644)."
        }
      },
      required: [:app, :path, :sha256, :size, :mode],
      additionalProperties: false
    },
    struct?: false
  )
end
