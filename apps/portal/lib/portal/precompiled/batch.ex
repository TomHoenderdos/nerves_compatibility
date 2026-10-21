defmodule Portal.Precompiled.Batch do
  @moduledoc """
  One signed batch index: the sequence, issue and expiry, the payload bytes
  and the signatures over them. Append-only; the table is the public
  history the signing RFC asks for.
  """
  use Ash.Resource, domain: Portal.Precompiled, data_layer: AshPostgres.DataLayer

  postgres do
    table("precompiled_batches")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:sequence, :issued_at, :expires_at, :payload, :signatures, :manifest_count])
    end
  end

  identities do
    identity(:unique_sequence, [:sequence])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:sequence, :integer, allow_nil?: false, public?: true)
    attribute(:issued_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:payload, :string, allow_nil?: false, public?: true)
    attribute(:signatures, {:array, :map}, allow_nil?: false, public?: true)
    attribute(:manifest_count, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end
end
