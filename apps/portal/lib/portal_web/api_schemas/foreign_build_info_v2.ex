defmodule PortalWeb.ApiSchemas.ForeignBuildInfoV2 do
  @moduledoc "What a format-2 foreign priv build was built with."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.BuildInfoV2

  @base BuildInfoV2.schema()

  OpenApiSpex.schema(
    %{
      title: "ForeignBuildInfoV2",
      description:
        "`BuildInfoV2` plus the foreign priv fields, only on a build under a version's " <>
          "`foreign_priv` object.",
      type: :object,
      properties:
        Map.merge(@base.properties, %{
          foreign_priv_rule: %Schema{
            type: :string,
            enum: Enum.map(Compatibility.ForeignPriv.rules(), & &1.id),
            description:
              "The reviewed rule the build's `foreign_priv` files were let through by. A " <>
                "client that does not know it does not take the build."
          },
          foreign_priv_target: %Schema{
            type: :string,
            enum: [Compatibility.ForeignPriv.target()],
            description:
              "On a build of the app foreign priv builds write into (kino) itself: it is " <>
                "listed only here, where clients from 0.8.0 on read it."
          }
        }),
      required: @base.required,
      additionalProperties: false
    },
    struct?: false
  )
end
