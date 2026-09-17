defmodule Portal.Catalog.Run do
  @moduledoc """
  One scan execution for a (package, version, image_digest). Envelope of
  the legacy `result.json`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_runs")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id])
      index([:scan_request_id])
      index([:finished_at])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :run_id,
        :package_id,
        :version_tested,
        :image_digest,
        :overall_status,
        :footprint,
        :toolchain,
        :log,
        :started_at,
        :finished_at,
        :scan_request_id
      ])
    end

    update :update do
      accept([
        :overall_status,
        :footprint,
        :toolchain,
        :log,
        :started_at,
        :finished_at,
        :scan_request_id
      ])
    end
  end

  identities do
    identity(:unique_run_id, [:run_id])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :run_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :version_tested, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :image_digest, :string do
      public?(true)
    end

    attribute :overall_status, :atom do
      public?(true)
      constraints(one_of: [:pass, :fail, :error, :skipped, :unknown])
    end

    attribute :footprint, :map do
      public?(true)
    end

    # The Elixir and OTP versions the worker ran under, as reported by
    # `NccWorker.Worker.detect_toolchain/0`. A stored `.beam` is only safely
    # reusable against a matching OTP major, so anything that hands these blobs
    # to a consumer has to be able to state what they were built with. The
    # worker has always emitted this; it was simply dropped on ingest.
    attribute :toolchain, :map do
      public?(true)
    end

    attribute :log, :string do
      public?(true)
    end

    attribute :started_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :finished_at, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :package, Portal.Catalog.Package do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :scan_request, Portal.ScanRequests.ScanRequest do
      allow_nil?(true)
      public?(true)
      attribute_type(:uuid)
      define_attribute?(true)
    end

    has_many :system_results, Portal.Catalog.SystemResult do
      public?(true)
    end
  end
end
