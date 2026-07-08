defmodule Portal.Catalog.SystemResult do
  @moduledoc """
  One row per (package × Nerves system × run). Replaces the entries of
  `latest_by_pkg_system.json`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_system_results")
    repo(Portal.Repo)

    custom_indexes do
      index([:run_id])
      index([:system_pkg, :status])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :run_id,
        :system_pkg,
        :system_version,
        :status,
        :firmware_size_bytes,
        :hex_version_tested,
        :beam_scan,
        :dependency_scans,
        :log_path,
        :log_tail,
        :failure_category
      ])
    end

    update :update do
      accept([
        :status,
        :firmware_size_bytes,
        :hex_version_tested,
        :beam_scan,
        :dependency_scans,
        :log_path,
        :failure_category
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :system_pkg, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :system_version, :string do
      public?(true)
    end

    # Mirrors Compatibility.Types.status/0
    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:pass, :fail, :error, :skipped, :unknown])
    end

    attribute :firmware_size_bytes, :integer do
      public?(true)
    end

    attribute :hex_version_tested, :string do
      public?(true)
    end

    attribute :beam_scan, :map do
      public?(true)
    end

    attribute :dependency_scans, :map do
      public?(true)
    end

    attribute :log_path, :string do
      public?(true)
    end

    attribute :log_tail, :string do
      public?(true)
    end

    attribute :failure_category, :string do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :run, Portal.Catalog.Run do
      allow_nil?(false)
      public?(true)
    end

    has_many :artifacts, Portal.Catalog.Artifact do
      public?(true)
    end
  end
end
