defmodule Portal.Precompiled do
  @moduledoc "Signed publication of precompiled manifests: batches, keys, root."
  use Ash.Domain

  resources do
    resource(Portal.Precompiled.Batch)
  end
end
