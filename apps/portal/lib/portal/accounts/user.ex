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
      index([:hex_username])
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
        :password_hash,
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
        :last_github_login_at
      ])
    end

    update :set_admin do
      accept([:is_admin])
    end

    update :update_profile do
      accept([:username, :password_hash])
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

    attribute :password_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :is_admin, :boolean do
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
