defmodule PortalWeb.ApiSchemas.ForeignLists do
  @moduledoc "A format-2 version's `foreign_priv` object."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.ForeignManifestBuild

  OpenApiSpex.schema(
    %{
      title: "ForeignLists",
      description:
        "Foreign priv builds (packages whose compile writes Kino.JS asset archives into " <>
          "kino's build `priv`, rule `kino_js_v1`) and kino's own builds, in the same lists " <>
          "as the version's own. Only clients 0.8.0 and later read this key, after the " <>
          "version's other lists missed. Absent when the version has none or while the " <>
          "portal's `foreign_priv_enabled` setting is off.",
      type: :object,
      properties: %{
        builds: %Schema{type: :array, items: ForeignManifestBuild},
        builds_with_inputs: %Schema{type: :array, items: ForeignManifestBuild},
        builds_closure: %Schema{type: :array, items: ForeignManifestBuild}
      },
      required: [:builds],
      additionalProperties: false
    },
    struct?: false
  )
end
