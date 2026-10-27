defmodule PortalWeb.ApiSchemas.NativeComponents do
  @moduledoc "What native code a package carries."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "NativeComponents",
      description:
        "What native code the package carries, as detected from its source. Every field is " <>
          "optional: an assessed result may carry only `compatibility_basis`.",
      type: :object,
      nullable: true,
      properties: %{
        nif_language: %Schema{
          type: :string,
          nullable: true,
          description: "Language of the package's NIF (`rust`, `zig`, `c`, ...), or null."
        },
        port_languages: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Languages of port programs the package ships."
        },
        evidence: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "What the detection was based on."
        },
        compatibility_basis: %Schema{
          type: :string,
          description:
            "How the verdict was reached, for example `firmware`, `pure_elixir`, " <>
              "`registry_deps` or `nerves_tooling` (see the catalog format document)."
        }
      }
    },
    struct?: false
  )
end
