defmodule PortalWeb.ApiSchemas.CompileEnvEntry do
  @moduledoc "One `compile_env` read recorded for a build."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CompileEnvEntry",
      description: "One `compile_env` read from the package's `.app` file.",
      type: :object,
      properties: %{
        app: %Schema{type: :string},
        path: %Schema{type: :array, items: %Schema{type: :string}},
        value: %Schema{
          type: :string,
          description: "`base64url(:erlang.term_to_binary({:ok, v} | :error, [:deterministic]))`."
        }
      },
      required: [:app, :path, :value],
      additionalProperties: false
    },
    struct?: false
  )
end
