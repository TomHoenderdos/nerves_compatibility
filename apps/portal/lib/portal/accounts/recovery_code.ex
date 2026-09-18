defmodule Portal.Accounts.RecoveryCode do
  @moduledoc """
  One row per issued recovery code, holding only a SHA-256 hash of it.

  SHA-256 rather than Argon2 is deliberate: these are 80 bits of CSPRNG
  output, so there is nothing to brute-force, and Argon2 would cost up to ten
  ~100 ms verifications per login attempt. The two choices are coupled — see
  the spec before shortening the codes.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_recovery_codes")
    repo(Portal.Repo)

    custom_indexes do
      index([:user_id])
      index([:code_hash])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:code_hash, :user_id])
    end

    update :consume do
      accept([:used_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :code_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :used_at, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :user, Portal.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end
end
