defmodule PortalWeb.ApiSchemas.CompileInputItem do
  @moduledoc "One compile-time input recorded for a build (`Compatibility.CompileInputs`)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "CompileInputItem",
      description:
        "An environment variable or config the build's compile read that a client checks " <>
          "itself. `env` items carry `name`, `value` and `set_by` (`inputs` too when " <>
          "`set_by` is `build`); `env_all` and `config_unrecorded` carry `kind` alone; " <>
          "`config_order` items carry `app`, `path`, `reader`, `default` and `seen`.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: ["env", "env_all", "config_unrecorded", "config_order"]
        },
        name: %Schema{type: :string},
        app: %Schema{type: :string},
        path: %Schema{type: :array, items: %Schema{type: :string}, minItems: 1, maxItems: 1},
        reader: %Schema{
          type: :string,
          description: "The application whose compile made the read."
        },
        default: %Schema{
          type: :string,
          description:
            "`app`'s `.app` env default for the key at the locked version, recorded like `value` " <>
              "(`:error` when the `.app` declares none), or `unrecordable`."
        },
        seen: %Schema{
          type: :string,
          description:
            "What the reader's read returned, recorded like `value`, or `unrecordable`."
        },
        value: %Schema{
          type: :string,
          description:
            "`base64url(:erlang.term_to_binary(:error | {:ok, binary}, [:deterministic]))`, " <>
              "or `unrecordable`, which matches nothing."
        },
        set_by: %Schema{type: :string, enum: ["host", "build"]},
        inputs: %Schema{type: :string, enum: ["recorded", "unknown"]}
      },
      required: [:kind],
      additionalProperties: false
    },
    struct?: false
  )
end
