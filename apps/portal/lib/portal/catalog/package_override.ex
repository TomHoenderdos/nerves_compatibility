defmodule Portal.Catalog.PackageOverride do
  @moduledoc """
  Admin-editable overrides for a package's compatibility result. Replaces
  the legacy `package_metadata.json` file.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_package_overrides")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:package_name, :forced_status, :allow_systems, :deny_systems, :notes])
    end

    update :update do
      accept([:forced_status, :allow_systems, :deny_systems, :notes])
    end
  end

  identities do
    identity(:unique_package_name, [:package_name])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :package_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :forced_status, :atom do
      public?(true)
      constraints(one_of: [:pass, :fail, :error, :skipped, :unknown])
    end

    attribute :allow_systems, {:array, :string} do
      public?(true)
      default([])
    end

    attribute :deny_systems, {:array, :string} do
      public?(true)
      default([])
    end

    attribute :notes, :string do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
