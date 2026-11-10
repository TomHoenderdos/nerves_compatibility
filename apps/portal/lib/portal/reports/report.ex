defmodule Portal.Reports.Report do
  @moduledoc """
  One miss report as a client sent it, after `Portal.Reports.Payload` checked
  it. `payload_hash` identifies identical reports (`Portal.Reports.record/3`
  counts a repeat within 24 hours in `seen_count` instead of storing it again).
  `lock` holds `%{"entries" => [%{"name", "version", "checksum"}]}`: the public
  Hex lock entries of the report's candidates and their closure.
  """

  use Ash.Resource,
    domain: Portal.Reports,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("precompiled_reports")
    repo(Portal.Repo)

    custom_indexes do
      index([:received_at])
      index([:payload_hash, :received_at])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :received_at,
        :built_at,
        :payload_hash,
        :format,
        :client,
        :elixir,
        :otp,
        :os_family,
        :os_arch,
        :target,
        :system,
        :system_version,
        :contact,
        :reporter_key,
        :lock,
        :hit_count,
        :miss_count,
        :fail_count
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :received_at, :utc_datetime_usec do
      allow_nil?(false)
      default(&DateTime.utc_now/0)
      public?(true)
    end

    attribute(:built_at, :utc_datetime_usec, public?: true)

    attribute :payload_hash, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :seen_count, :integer do
      allow_nil?(false)
      default(1)
      public?(true)
    end

    attribute(:format, :integer, allow_nil?: false, public?: true)
    attribute(:client, :string, allow_nil?: false, public?: true)
    attribute(:elixir, :string, allow_nil?: false, public?: true)
    attribute(:otp, :integer, allow_nil?: false, public?: true)
    attribute(:os_family, :string, allow_nil?: false, public?: true)
    attribute(:os_arch, :string, allow_nil?: false, public?: true)
    attribute(:target, :string, allow_nil?: false, public?: true)
    attribute(:system, :string, public?: true)
    attribute(:system_version, :string, public?: true)
    attribute(:contact, :string, public?: true)
    attribute(:reporter_key, :string, public?: true)

    attribute :lock, :map do
      allow_nil?(false)
      default(%{"entries" => []})
      public?(true)
    end

    attribute(:hit_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:miss_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:fail_count, :integer, allow_nil?: false, default: 0, public?: true)
  end

  relationships do
    has_many :lines, Portal.Reports.Line do
      public?(true)
    end
  end
end
