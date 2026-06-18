defmodule Portal.ScanRequests.ScanRequest do
  @moduledoc """
  A package scan request submitted through the portal.
  """

  use Ash.Resource,
    domain: Portal.ScanRequests,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("portal_scan_requests")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_name, :status], name: "portal_scan_requests_package_status_index")
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :package_name,
        :version,
        :source,
        :status,
        :user_id,
        :subject,
        :verification_provider,
        :error_reason
      ])
    end

    update :review do
      accept([
        :status,
        :error_reason
      ])
    end

    update :replace_open_request do
      accept([
        :source,
        :status,
        :user_id,
        :subject,
        :verification_provider,
        :error_reason
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :package_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :version, :string do
      public?(true)
    end

    attribute :source, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:hex_owner, :github_repo, :anonymous_turnstile, :anonymous_manual])
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:accepted)
      constraints(one_of: [:pending, :accepted, :queued, :rejected])
    end

    attribute :user_id, :uuid do
      public?(true)
    end

    attribute :subject, :string do
      public?(true)
    end

    attribute :verification_provider, :string do
      public?(true)
    end

    attribute :error_reason, :string do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
