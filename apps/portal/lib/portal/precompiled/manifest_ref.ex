defmodule Portal.Precompiled.ManifestRef do
  @moduledoc """
  A manifest sha some signed batch named, per format (1 or 2). The by-sha
  manifest routes serve a stored blob only when it is here: the artifact store
  holds file blobs too, which only the files route serves, behind its
  publication gate. Written by `Portal.Precompiled.ManifestRefs.record/3` in
  the transaction that inserts the batch naming it; never updated or deleted.
  """
  use Ash.Resource, domain: Portal.Precompiled, data_layer: AshPostgres.DataLayer

  postgres do
    table("precompiled_manifest_refs")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])
  end

  attributes do
    attribute(:sha256, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:format, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:first_sequence, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end
end
