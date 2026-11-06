defmodule Portal.Catalog.CoverageReport do
  @moduledoc """
  The last `Portal.Catalog.Coverage.report/1`, as
  `Portal.Workers.CoverageRefresh` stored it, and when it was computed.

  Computing the report asks the Hex registry about every ranked package, so
  the admin Maintenance page shows this stored copy rather than computing it
  on each load. One row, keyed `"latest"`, replaced by each refresh; read it
  through `Portal.Catalog.Coverage.latest/0`, which gives the report back in
  the shape `report/1` returns.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_coverage_reports")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :upsert do
      accept([:key, :report, :computed_at])
      upsert?(true)
      upsert_identity(:unique_key)
      upsert_fields([:report, :computed_at])
    end
  end

  identities do
    identity(:unique_key, [:key])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      default("latest")
      public?(true)
    end

    attribute :report, :map do
      allow_nil?(false)
      public?(true)
    end

    attribute :computed_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
