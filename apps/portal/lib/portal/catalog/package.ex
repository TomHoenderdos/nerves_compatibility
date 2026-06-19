defmodule Portal.Catalog.Package do
  @moduledoc """
  One row per Hex package. Replaces the top level of `latest_by_pkg.json`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_packages")
    repo(Portal.Repo)

    custom_indexes do
      index([:name], unique: true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name, :description, :latest_version, :last_run_at])
    end

    update :update do
      accept([:description, :latest_version, :last_run_at])
    end

    create :upsert do
      accept([:name, :description, :latest_version, :last_run_at])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields([:description, :latest_version, :last_run_at])
    end
  end

  identities do
    identity(:unique_name, [:name])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :description, :string do
      public?(true)
    end

    attribute :latest_version, :string do
      public?(true)
    end

    attribute :last_run_at, :utc_datetime do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :runs, Portal.Catalog.Run do
      public?(true)
    end
  end
end
