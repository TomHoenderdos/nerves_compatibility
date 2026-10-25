defmodule Portal.Builders.EnrolmentToken do
  @moduledoc "A one-time token (stored hashed) that lets one machine enrol as a builder."
  use Ash.Resource, domain: Portal.Builders, data_layer: AshPostgres.DataLayer

  postgres do
    table("builder_enrolment_tokens")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:token_hash, :name, :created_by, :expires_at])
    end

    update :use do
      accept([:builder_id])
      change(set_attribute(:used_at, &DateTime.utc_now/0))
    end

    # Test convenience: make the token expired.
    update :expire_now do
      change(set_attribute(:expires_at, &__MODULE__.an_hour_ago/0))
    end
  end

  identities do
    identity(:unique_token_hash, [:token_hash])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:token_hash, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:created_by, :string, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:used_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :builder, Portal.Builders.Builder do
      allow_nil?(true)
      public?(true)
      attribute_type(:uuid)
      define_attribute?(true)
    end
  end

  @doc false
  def an_hour_ago, do: DateTime.add(DateTime.utc_now(), -3600, :second)
end
