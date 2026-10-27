defmodule PortalWeb.ApiSchemas.DepLockEntry do
  @moduledoc "One dependency a build was compiled against."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "DepLockEntry",
      type: :object,
      properties: %{
        version: %Schema{type: :string},
        checksum: %Schema{
          type: :string,
          description: "The outer Hex checksum, as the last element of a `mix.lock` entry."
        }
      },
      required: [:version, :checksum]
    },
    struct?: false
  )
end
