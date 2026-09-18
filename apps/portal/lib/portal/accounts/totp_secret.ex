defmodule Portal.Accounts.TotpSecret do
  @moduledoc """
  One TOTP secret per user.

  An unconfirmed secret never counts as a factor — a half-finished enrolment
  that counted would lock the user out of their own account.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_totp_secrets")
    repo(Portal.Repo)
  end

  identities do
    identity(:unique_user, [:user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:secret, :user_id])
    end

    update :confirm do
      accept([:confirmed_at, :last_used_at, :failed_attempts])
    end

    update :record_success do
      accept([:last_used_at, :failed_attempts, :locked_until])
    end

    update :record_failure do
      accept([:failed_attempts, :locked_until])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :secret, :binary do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :confirmed_at, :utc_datetime_usec do
      public?(true)
    end

    # The moment the last accepted code was used. Handed straight to
    # `NimbleTOTP.valid?(secret, code, since: last_used_at)`, which rejects a
    # code minted inside an already-consumed window.
    attribute :last_used_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :failed_attempts, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :locked_until, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Portal.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end
end
