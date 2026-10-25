defmodule Portal.Builders.Builder do
  @moduledoc "A remote build machine, identified by its current client certificate's fingerprint."
  use Ash.Resource, domain: Portal.Builders, data_layer: AshPostgres.DataLayer

  postgres do
    table("builders")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :enrol do
      accept([
        :name,
        :fingerprint,
        :cert_pem,
        :cert_expires_at,
        :slots,
        :last_version,
        :enrolled_at
      ])
    end

    update :touch do
      accept([:last_seen_at, :last_version])
    end

    update :set_publishing do
      accept([:publishing])
    end

    update :set_slots do
      accept([:slots])
    end

    update :set_egress do
      accept([:egress_status])
    end

    update :set_note do
      accept([:note])
    end

    update :rotate_cert do
      accept([:fingerprint, :cert_pem, :cert_expires_at])
    end

    update :revoke do
      change(set_attribute(:status, :revoked))
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_name, [:name])
    identity(:unique_fingerprint, [:fingerprint])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:fingerprint, :string, allow_nil?: false, public?: true)
    attribute(:cert_pem, :string, allow_nil?: false, public?: true)
    attribute(:cert_expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      default(:enrolled)
      public?(true)
      constraints(one_of: [:enrolled, :revoked])
    end

    # Default false on purpose: a new machine's runs count for the tracker
    # but its files are not published until an admin has looked at them.
    attribute(:publishing, :boolean, allow_nil?: false, default: false, public?: true)

    attribute :slots, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
      constraints(min: 1, max: 16)
    end

    attribute(:enrolled_at, :utc_datetime_usec, public?: true)
    attribute(:last_seen_at, :utc_datetime_usec, public?: true)
    attribute(:last_version, :string, public?: true)
    attribute(:egress_status, :string, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    attribute(:note, :string, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:certificates, Portal.Builders.BuilderCertificate, public?: true)
    has_many(:leases, Portal.Builders.Lease, public?: true)
  end
end
