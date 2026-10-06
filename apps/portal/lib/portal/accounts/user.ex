defmodule Portal.Accounts.User do
  @moduledoc """
  Internal portal user linked to external identity providers.

  Hex access tokens are intentionally not persisted. The portal stores stable
  identity metadata and uses short-lived OAuth results only during verification.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_users")
    repo(Portal.Repo)

    custom_indexes do
      index([:username], unique: true)
      # One account per identity. Partial, so any number of accounts can have
      # no link at all.
      index([:hex_username], unique: true, where: "hex_username IS NOT NULL")
      index([:github_id], unique: true, where: "github_id IS NOT NULL")
      index([:github_username])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :username,
        :hex_username,
        :hex_profile,
        :github_username,
        :github_profile,
        :github_id,
        :password_hash,
        :password_set,
        :is_admin,
        :last_hex_login_at,
        :last_github_login_at
      ])
    end

    update :record_hex_login do
      accept([
        :hex_username,
        :hex_profile,
        :last_hex_login_at
      ])
    end

    update :record_github_login do
      accept([
        :github_username,
        :github_profile,
        :github_id,
        :last_github_login_at
      ])
    end

    update :set_admin do
      accept([:is_admin])
    end

    update :update_profile do
      accept([:username, :password_hash, :password_reset_required, :password_set])
    end

    # Link or unlink providers. `Portal.Accounts.Identities` is the only
    # caller; it owns the rules about when that is allowed.
    update :set_links do
      accept([:hex_username, :hex_profile, :github_username, :github_profile, :github_id])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :username, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :hex_username, :string do
      public?(true)
    end

    attribute :hex_profile, :string do
      public?(true)
      default("{}")
    end

    attribute :github_username, :string do
      public?(true)
    end

    attribute :github_profile, :string do
      public?(true)
      default("{}")
    end

    # GitHub's numeric user id. Links match on this, never on the login name,
    # which a user can change and someone else can then register.
    attribute :github_id, :integer do
      public?(true)
    end

    attribute :password_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    # False for accounts a provider sign-in created: their password hash is
    # random and nobody knows it. Settings then offers "Set a password".
    attribute :password_set, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :is_admin, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Set when an admin hands out a temporary password; cleared when the user
    # chooses their own. Login sends such a user straight to settings.
    attribute :password_reset_required, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :last_hex_login_at, :utc_datetime do
      public?(true)
    end

    attribute :last_github_login_at, :utc_datetime do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
