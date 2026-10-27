defmodule Portal.Builders.Lease do
  @moduledoc """
  The remote job queue: one row per build handed to a remote builder. `args`
  is the `Portal.Workers.Build` job args (string keys).
  """
  use Ash.Resource, domain: Portal.Builders, data_layer: AshPostgres.DataLayer

  postgres do
    table("builder_leases")
    repo(Portal.Repo)

    custom_indexes do
      index([:state, :priority, :inserted_at], name: "builder_leases_queue_index")
      index([:builder_id])
      # Served by `Portal.BulkRebuild`'s lookup of a `RemoteBuild` job's
      # newest lease, keyed by `scan_request_id` once the query casts the
      # JSON side to uuid instead of casting this column to text.
      index([:scan_request_id])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :package,
        :version,
        :image_name,
        :image_digest,
        :args,
        :scan_request_id,
        :priority,
        :state,
        :builder_id,
        :leased_at,
        :heartbeat_at,
        :phase,
        :log_tail,
        :attempt,
        :max_attempts,
        :run_id,
        :bytes_uploaded,
        :error
      ])
    end

    update :update do
      accept([
        :state,
        :builder_id,
        :leased_at,
        :heartbeat_at,
        :phase,
        :log_tail,
        :attempt,
        :run_id,
        :bytes_uploaded,
        :error
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:package, :string, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:image_name, :string, allow_nil?: false, public?: true)
    attribute(:image_digest, :string, allow_nil?: false, public?: true)
    attribute(:args, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:scan_request_id, :uuid, public?: true)

    attribute :priority, :integer do
      allow_nil?(false)
      default(5)
      public?(true)
    end

    attribute :state, :atom do
      allow_nil?(false)
      default(:queued)
      public?(true)
      constraints(one_of: [:queued, :leased, :uploading, :done, :failed])
    end

    attribute(:leased_at, :utc_datetime_usec, public?: true)
    attribute(:heartbeat_at, :utc_datetime_usec, public?: true)
    attribute(:phase, :string, public?: true)
    attribute(:log_tail, :string, public?: true)
    attribute(:attempt, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:max_attempts, :integer, allow_nil?: false, default: 3, public?: true)
    attribute(:run_id, :string, public?: true)
    attribute(:bytes_uploaded, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:error, :string, public?: true)
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
end
