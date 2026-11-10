defmodule Portal.Reports.Quota do
  @moduledoc """
  One requeue counter per key and UTC day (`Portal.Reports.Quotas`): `global`,
  `package:<name>` or `reporter:<key>`. Written only by
  `Portal.Reports.Quotas.reserve/2`'s single-statement increments.
  """

  use Ash.Resource,
    domain: Portal.Reports,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("precompiled_report_quotas")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])
  end

  identities do
    identity(:unique_key_day, [:key, :day])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:day, :date, allow_nil?: false, public?: true)
    attribute(:used, :integer, allow_nil?: false, default: 0, public?: true)
    create_timestamp(:inserted_at)
  end
end
