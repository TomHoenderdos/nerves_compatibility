defmodule PortalWeb.ApiSchemas.DeclaredDep do
  @moduledoc "One dependency a package declares, as its lock entry lists it."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "DeclaredDep",
      type: :object,
      properties: %{
        app: %Schema{type: :string, description: "The OTP application name."},
        name: %Schema{type: :string, description: "The Hex package name."},
        requirement: %Schema{type: :string},
        optional: %Schema{type: :boolean}
      },
      required: [:app, :name, :requirement, :optional],
      additionalProperties: false
    },
    struct?: false
  )
end
