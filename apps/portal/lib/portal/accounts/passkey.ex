defmodule Portal.Accounts.Passkey do
  @moduledoc """
  A registered WebAuthn credential. Many per user, so a laptop and a phone can
  both sign in.

  Nothing here lives on `Portal.Accounts.User`: that struct is assigned as
  `current_user` on every LiveView mount and passed into layouts, so anything
  stored on it is one `inspect` away from a log line.
  """

  use Ash.Resource,
    domain: Portal.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_passkeys")
    repo(Portal.Repo)

    custom_indexes do
      index([:user_id])
    end
  end

  identities do
    identity(:unique_credential_id, [:credential_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :credential_id,
        :public_key,
        :sign_count,
        :aaguid,
        :transports,
        :nickname,
        :user_id
      ])
    end

    update :record_use do
      accept([:sign_count, :last_used_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :credential_id, :binary do
      allow_nil?(false)
    end

    # The COSE key from Wax, through `:erlang.term_to_binary/1`. Read it back
    # with `:erlang.binary_to_term(bin, [:safe])` — never a bare
    # `binary_to_term/1` on a value that round-tripped through storage.
    attribute :public_key, :binary do
      allow_nil?(false)
    end

    attribute :sign_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute :aaguid, :binary do
      public?(true)
    end

    attribute :transports, {:array, :string} do
      public?(true)
    end

    attribute :nickname, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :last_used_at, :utc_datetime_usec do
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
