defmodule Portal.Repo.Migrations.AddSystemResultDeterministicBuilds do
  @moduledoc """
  A firmware target's deterministic sibling (`NccWorker.FirmwareDeterministic`)
  is owned by the target's system result:
  `catalog_deterministic_builds.system_result_id`, a third possible owner
  beside `toolchain_build_id` and `pinned_build_id`, removed with its system
  result, with `one_build` widened to the three and a unique index.

  Add-only for the release still running during the deploy window: it never
  writes the new column, so each of its siblings keeps exactly one of its two
  owners and satisfies the wider check as it did the old one. No existing
  index changes.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_deterministic_builds) do
      add(
        :system_result_id,
        references(:catalog_system_results,
          column: :id,
          name: "catalog_deterministic_builds_system_result_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        )
      )
    end

    drop(constraint(:catalog_deterministic_builds, :one_build))

    create(
      constraint(:catalog_deterministic_builds, :one_build,
        check: "num_nonnulls(toolchain_build_id, pinned_build_id, system_result_id) = 1"
      )
    )

    create(
      unique_index(:catalog_deterministic_builds, [:system_result_id],
        name: "catalog_deterministic_builds_unique_system_result_index"
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DELETE FROM catalog_deterministic_builds WHERE system_result_id IS NOT NULL")
    drop(constraint(:catalog_deterministic_builds, :one_build))

    drop(
      index(:catalog_deterministic_builds, [:system_result_id],
        name: "catalog_deterministic_builds_unique_system_result_index"
      )
    )

    alter table(:catalog_deterministic_builds) do
      remove(:system_result_id)
    end

    create(
      constraint(:catalog_deterministic_builds, :one_build,
        check: "num_nonnulls(toolchain_build_id, pinned_build_id) = 1"
      )
    )
  end
end
