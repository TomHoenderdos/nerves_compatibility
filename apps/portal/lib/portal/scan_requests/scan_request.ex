defmodule Portal.ScanRequests.ScanRequest do
  @moduledoc """
  A package scan request submitted through the portal.
  """

  use Ash.Resource,
    domain: Portal.ScanRequests,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("portal_scan_requests")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_name, :status], name: "portal_scan_requests_package_status_index")
      index([:status])
      index([:source])
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

    update :set_status do
      accept([
        :status,
        :error_reason,
        :error_log,
        :run_id
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

      # `:admin_manual` is an admin queueing a package from the admin page. It
      # is deliberately distinct from `:anonymous_manual`, which is a stranger's
      # submission waiting for review: the two have opposite trust and opposite
      # priority, and folding them together would put admin requests into the
      # approval list they are meant to bypass.
      constraints(
        one_of: [
          :hex_owner,
          :github_repo,
          :anonymous_turnstile,
          :anonymous_manual,
          :admin_manual,
          :backfill
        ]
      )
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:accepted)
      constraints(one_of: [:pending, :accepted, :queued, :built, :rejected, :error])
    end

    attribute :user_id, :uuid do
      public?(true)
    end

    attribute :run_id, :uuid do
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

    attribute :error_log, :string do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
