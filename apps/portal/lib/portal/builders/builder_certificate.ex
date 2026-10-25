defmodule Portal.Builders.BuilderCertificate do
  @moduledoc "One client certificate a builder has held; superseded when it rotates."
  use Ash.Resource, domain: Portal.Builders, data_layer: AshPostgres.DataLayer

  postgres do
    table("builder_certificates")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:builder_id, :fingerprint, :issued_at, :expires_at])
    end

    update :supersede do
      change(set_attribute(:superseded_at, &DateTime.utc_now/0))
    end

    # Test convenience: backdate the supersession.
    update :update_superseded_at do
      accept([:superseded_at])
    end
  end

  identities do
    identity(:unique_fingerprint, [:fingerprint])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:fingerprint, :string, allow_nil?: false, public?: true)
    attribute(:issued_at, :utc_datetime_usec, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true)
    attribute(:superseded_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :builder, Portal.Builders.Builder do
      allow_nil?(false)
      public?(true)
      attribute_type(:uuid)
    end
  end
end
