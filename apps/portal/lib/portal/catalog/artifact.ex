defmodule Portal.Catalog.Artifact do
  @moduledoc """
  Content-addressed build artifact (firmware, precompiled BEAM, etc).
  Blob lives on disk at `disk_path`; the database stores metadata only.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_artifacts")
    repo(Portal.Repo)

    custom_indexes do
      index([:system_result_id])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:sha256, :byte_size, :disk_path, :system_result_id])
    end

    create :upsert do
      accept([:sha256, :byte_size, :disk_path, :system_result_id])
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

  relationships do
    belongs_to :system_result, Portal.Catalog.SystemResult do
      allow_nil?(false)
      public?(true)
    end
  end
end
