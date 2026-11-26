defmodule PortalWeb.ApiSchemas.ReleaseIndexDoc do
  @moduledoc """
  A release index document a batch names under `release_index` (S10 round
  5, `Portal.Catalog.ReleaseIndex`): a shard of the read releases, or one
  probed module's definer set.
  """
  require OpenApiSpex
  alias OpenApiSpex.Schema

  @versions %Schema{
    type: :object,
    description: "Hex package name to its versions, sorted.",
    additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
  }

  OpenApiSpex.schema(%{
    title: "ReleaseIndexDoc",
    type: :object,
    properties: %{
      format: %Schema{type: :integer, enum: [1]},
      shard: %Schema{
        type: :string,
        pattern: "^[0-9a-f]{2}$",
        description:
          "A shard: the first byte, in hex, of the SHA-256 of each package name it holds."
      },
      read: %Schema{
        type: :object,
        description:
          "The releases the index has read, by package: each `[version, outer checksum]`, " <>
            "the registry's outer checksum of the tarball it was read from, sorted. A lock " <>
            "with another outer checksum for the release (one replaced since) does not match.",
        additionalProperties: %Schema{
          type: :array,
          items: %Schema{
            type: :array,
            items: %Schema{type: :string},
            minItems: 2,
            maxItems: 2
          }
        }
      },
      module: %Schema{type: :string, description: "A definer set: the probed module."},
      definers: %{@versions | description: "The read releases that define the module."}
    },
    required: [:format],
    additionalProperties: false
  })
end
