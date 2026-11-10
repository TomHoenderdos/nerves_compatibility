defmodule Portal.Reports.Line do
  @moduledoc """
  One MISS or FAIL line of a `Portal.Reports.Report`. `reason_code` is one of
  `Portal.Reports.Payload.known_codes/0`, or `"unknown"`. `requeue` is nil
  until `Portal.Reports.Requeue` decides a not-built line: `"queued"` or
  `"skipped:<why>"`.
  """

  use Ash.Resource,
    domain: Portal.Reports,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("precompiled_report_lines")
    repo(Portal.Repo)

    references do
      reference(:report, on_delete: :delete, index?: true)
    end

    custom_indexes do
      index([:package, :version, :reason_code])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :report_id,
        :package,
        :version,
        :status,
        :reason_code,
        :reason_args,
        :reason,
        :requeue
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:package, :string, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:miss, :fail])
    end

    attribute(:reason_code, :string, allow_nil?: false, public?: true)

    attribute :reason_args, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute(:reason, :string, public?: true)
    attribute(:requeue, :string, public?: true)

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :report, Portal.Reports.Report do
      allow_nil?(false)
      public?(true)
    end
  end
end
