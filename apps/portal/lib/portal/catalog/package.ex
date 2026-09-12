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
      accept([:name, :description, :latest_version, :last_run_at, :native_components])
    end

    update :update do
      accept([:description, :latest_version, :last_run_at])
    end

    # Separate from `:update` because the two have different writers and
    # different cadences: `:update` follows a build, this follows a hex.pm
    # lookup. Sharing one action would let a stale metadata fetch clobber a
    # freshly ingested `latest_version`.
    update :update_hex_meta do
      accept([:hex_links, :hex_owners])
      change(set_attribute(:hex_meta_fetched_at, &DateTime.utc_now/0))
    end

    create :upsert do
      accept([:name, :description, :latest_version, :last_run_at, :native_components])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields([:description, :latest_version, :last_run_at, :native_components])
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

    attribute :native_components, :map do
      public?(true)
    end

    # The package author's own `meta.links` from hex.pm -- label to URL, e.g.
    # `%{"GitHub" => "https://github.com/..."}`. Stored rather than derived
    # because nothing in a package name says where its source lives, and asking
    # hex.pm on every page render would put an external request in the path of a
    # page we serve ~2,500 of.
    #
    # Values are filtered to absolute http/https URLs by
    # `Portal.HexPm.package_metadata/1` before they ever reach this column.
    attribute :hex_links, :map do
      public?(true)
    end

    # Hex.pm usernames only. The upstream `owners` payload also carries each
    # owner's email address; `Portal.HexPm.package_metadata/1` drops those at
    # the API boundary so they never reach this column.
    attribute :hex_owners, {:array, :string} do
      public?(true)
    end

    # Nil means never fetched, which is how the backfill finds work and how the
    # page knows the difference between "this package has no links" and "we have
    # not looked yet".
    attribute :hex_meta_fetched_at, :utc_datetime do
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
