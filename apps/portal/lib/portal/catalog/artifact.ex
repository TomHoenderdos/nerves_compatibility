defmodule Portal.Catalog.Artifact do
  @moduledoc """
  Registry of content-addressed build artifacts (precompiled BEAM, NIFs, priv
  files). Blob lives on disk at `disk_path`; the database stores metadata only.

  One row per distinct sha256, and nothing more: a blob is shared by every
  system result that produced those exact bytes, so ownership does not belong
  here. `Portal.Catalog.ArtifactMembership` records which system results
  reference it, and explains what went wrong while this table tried to carry
  both.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_artifacts")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:sha256, :byte_size, :disk_path])
    end

    create :upsert do
      accept([:sha256, :byte_size, :disk_path])
      upsert?(true)
      upsert_identity(:unique_sha256)
      upsert_fields([:byte_size, :disk_path])
    end

    update :update do
      accept([:byte_size, :disk_path])
    end
  end

  identities do
    identity(:unique_sha256, [:sha256])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :sha256, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :byte_size, :integer do
      public?(true)
    end

    attribute :disk_path, :string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
