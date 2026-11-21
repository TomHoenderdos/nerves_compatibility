defmodule PortalWeb.ApiSchemas.RelocatedLists do
  @moduledoc "A format-2 version's `relocated` object."
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PortalWeb.ApiSchemas.RelocatedManifestBuild

  OpenApiSpex.schema(
    %{
      title: "RelocatedLists",
      description:
        "Relocated builds: toolchain builds whose own beams hold their build's deps or build " <>
          "path, each with the record of every occurrence a client rewrites to its project's " <>
          "own paths at install. In the same lists as the version's own. Only clients 0.9.0 " <>
          "and later read this key, after the version's other lists missed. Absent when the " <>
          "version has none or while the portal's `relocated_enabled` setting is off.",
      type: :object,
      properties: %{
        builds: %Schema{type: :array, items: RelocatedManifestBuild},
        builds_with_inputs: %Schema{type: :array, items: RelocatedManifestBuild},
        builds_closure: %Schema{type: :array, items: RelocatedManifestBuild}
      },
      required: [:builds],
      additionalProperties: false
    },
    struct?: false
  )
end
