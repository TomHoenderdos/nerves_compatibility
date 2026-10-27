defmodule PortalWeb.ApiSchemas.Status do
  @moduledoc "A build result status."
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "Status",
      description:
        "`pass`: the build succeeded. `fail`: it ran and failed. `error`: it hit an " <>
          "unexpected error. `skipped`: it was intentionally not built. `unknown`: no verdict.",
      type: :string,
      enum: ["pass", "fail", "error", "skipped", "unknown"]
    },
    struct?: false
  )
end
