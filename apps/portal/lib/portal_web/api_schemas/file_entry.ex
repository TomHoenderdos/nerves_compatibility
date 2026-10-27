defmodule PortalWeb.ApiSchemas.FileEntry do
  @moduledoc "One precompiled file listed in a manifest."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "FileEntry",
      description:
        "A file to install, fetched from `/api/precompiled/files/{sha256}` and checked " <>
          "against `sha256`.",
      type: :object,
      properties: %{
        path: %Schema{
          type: :string,
          description: "Relative path inside the package, under `ebin/` or `priv/`.",
          example: "ebin/Elixir.Jason.beam"
        },
        sha256: %Schema{
          type: :string,
          pattern: "^[0-9a-f]{64}$",
          description: "Lowercase hex SHA-256 of the file's bytes."
        },
        size: %Schema{
          type: :integer,
          minimum: 0,
          description: "Size in bytes, when it was recorded."
        },
        mode: %Schema{
          type: :integer,
          enum: [33_188, 33_261],
          description: "File mode to install with: `33188` (0o100644) or `33261` (0o100755)."
        }
      },
      required: [:path, :sha256, :mode]
    },
    struct?: false
  )
end
