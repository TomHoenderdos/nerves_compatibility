defmodule Portal.Catalog.SystemLog do
  @moduledoc """
  The full sanitized build log for one *failed* system result.

  A separate table rather than columns on `Portal.Catalog.SystemResult`, and
  that is structural rather than stylistic. The dashboard, badge and JSON paths
  read `catalog_system_results` whole; blob columns they never render are what
  drove a single page load to gigabytes and ran the node out of memory — see
  the comment above the field lists in `Portal.Catalog`. Keeping log bodies in
  their own table means no query on those paths can reach one by accident.

  One row per failed system result, enforced by a unique index. Passing builds
  store nothing: they are 97% of the log bytes and almost none of the value.
  See `docs/superpowers/specs/2026-09-10-build-log-viewer-design.md`.
  """

  use Ash.Resource, domain: Portal.Catalog, data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_system_logs")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:body, :byte_size, :truncated, :system_result_id])
    end
  end

  identities do
    identity(:unique_system_result, [:system_result_id])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
    end

    # Size of the log *before* truncation, so the page can say what was dropped.
    attribute :byte_size, :integer do
      public?(true)
    end

    attribute :truncated, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :system_result, Portal.Catalog.SystemResult do
      allow_nil?(false)
      public?(true)
    end
  end
end
