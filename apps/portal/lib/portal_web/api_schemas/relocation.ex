defmodule PortalWeb.ApiSchemas.Relocation do
  @moduledoc "A relocated build's record (`Compatibility.Relocation`)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @occurrence %Schema{
    type: :object,
    properties: %{
      chunk: %Schema{type: :string, enum: ["LitT", "AtU8", "Attr", "Line"]},
      index: %Schema{type: :integer, minimum: 0},
      term: %Schema{type: :array, items: %Schema{type: :integer, minimum: 0}},
      kind: %Schema{type: :string, enum: ["binary", "charlist", "atom"]},
      parts: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Text and slot names (`deps`, `build`) in turn, starting with text."
      }
    },
    required: [:chunk, :index, :term, :kind, :parts],
    additionalProperties: false
  }

  OpenApiSpex.schema(
    %{
      title: "Relocation",
      description:
        "The build's own `deps` and `build` paths, the second build's, and per beam to rewrite every occurrence of " <>
          "them: the chunk, the literal, atom or file name index, the path inside the term, " <>
          "the kind and the value as a template.",
      type: :object,
      properties: %{
        deps: %Schema{type: :string},
        build: %Schema{type: :string},
        second: %Schema{
          type: :object,
          description:
            "The second build's own `deps` and `build` paths: with the first, they span the " <>
              "paths a client relocates to.",
          properties: %{deps: %Schema{type: :string}, build: %Schema{type: :string}},
          required: [:deps, :build],
          additionalProperties: false
        },
        files: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              path: %Schema{type: :string},
              occurrences: %Schema{type: :array, items: @occurrence}
            },
            required: [:path, :occurrences],
            additionalProperties: false
          }
        }
      },
      required: [:deps, :build, :second, :files],
      additionalProperties: false
    },
    struct?: false
  )
end
