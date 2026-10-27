defmodule Portal.Catalog.BulkSweep do
  @moduledoc """
  One bulk rebuild an admin started (`Portal.BulkRebuild`). The work itself
  lives in Oban jobs tagged with this id in `meta.sweep_id`; this row is what
  stays once Oban prunes them, so the admin page can still list the sweep.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_bulk_sweeps")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:what, :systems, :options, :selected, :created_by])
    end

    update :cancel do
      accept([])
      change(set_attribute(:cancelled_at, &DateTime.utc_now/0))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :what, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/\A(full|argus_only|targets)\z/)
    end

    attribute(:systems, {:array, :string}, public?: true)
    attribute(:options, :map, public?: true)
    attribute(:selected, :integer, allow_nil?: false, public?: true)
    attribute(:created_by, :string, public?: true)
    attribute(:cancelled_at, :utc_datetime_usec, public?: true)

    create_timestamp(:inserted_at)
  end

  calculations do
    # Lives on the sweep's Oban jobs and remote leases, not this row; see
    # `Portal.BulkRebuild.status_many/1` for why.
    calculate :counts, :map, Portal.Catalog.Calculations.SweepCounts do
      public?(true)
    end
  end
end
