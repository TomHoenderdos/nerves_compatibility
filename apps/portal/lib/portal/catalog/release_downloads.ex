defmodule Portal.Catalog.ReleaseDownloads do
  @moduledoc """
  hex.pm's all-time download count for one package version, as
  `Portal.Workers.ReleaseDownloadsRefresh` last fetched it.

  `Portal.Catalog.toolchain_backlog/3` orders a package's versions by it, so
  the release projects actually lock is built before an old or pre-release
  one. Keyed by package name and version rather than a package row: a count
  is hex.pm's fact about a release, and the backlog joins on the names it
  already has.

  `downloads` is nil when hex.pm answered without a usable count; the version
  was asked about, but its demand is unknown and sorts last.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_release_downloads")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    # The weekly refresh writes the same versions again: one row each,
    # holding the newest count.
    create :upsert do
      accept([:package, :version, :downloads, :fetched_at])
      upsert?(true)
      upsert_identity(:unique_release)
      upsert_fields([:downloads, :fetched_at])
    end
  end

  identities do
    identity(:unique_release, [:package, :version])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :package, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :downloads, :integer do
      public?(true)
      constraints(min: 0)
    end

    attribute :fetched_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
