defmodule Portal.Repo.Migrations.AddFirmwareHoldSets do
  @moduledoc """
  The set of holds on a firmware build (stream S8, review S3): a system
  result's or pinned build's `unpublished_reason` and `unpublished_at` are
  one hold, `other_holds` the others (`%{"reason", "at"}` each). A row is
  served only when it has none: `Portal.Precompiled.Holds.undo/2` releases
  one hold and keeps the row withdrawn while another remains, and the check
  constraint refuses any write that clears `unpublished_at` while
  `other_holds` is not empty, so a bare undo of one hold fails rather than
  serve a row another still holds.

  `catalog_pinned_builds.firmware_judge`: a pinned firmware target's judge
  verdict (`NccWorker.FirmwareInputs`), as `catalog_system_results` keeps it.
  """

  use Ecto.Migration

  # Add-only and nullable, with no index. The constraints are NOT VALID: no
  # scan of the existing rows, which hold no `other_holds`, and the release
  # still running during the deploy window never writes the column. A bounded
  # lock wait fails the migration, and the deploy, loudly. SET LOCAL lasts for
  # the migration's own transaction only, so it must keep its DDL transaction.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_system_results) do
      add(:other_holds, {:array, :map})
    end

    alter table(:catalog_pinned_builds) do
      add(:other_holds, {:array, :map})
      add(:firmware_judge, :map)
    end

    execute("""
    ALTER TABLE catalog_system_results
      ADD CONSTRAINT catalog_system_results_holds_withdrawn
      CHECK (unpublished_at IS NOT NULL OR coalesce(cardinality(other_holds), 0) = 0) NOT VALID
    """)

    execute("""
    ALTER TABLE catalog_pinned_builds
      ADD CONSTRAINT catalog_pinned_builds_holds_withdrawn
      CHECK (unpublished_at IS NOT NULL OR coalesce(cardinality(other_holds), 0) = 0) NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute(
      "ALTER TABLE catalog_pinned_builds DROP CONSTRAINT IF EXISTS catalog_pinned_builds_holds_withdrawn"
    )

    execute(
      "ALTER TABLE catalog_system_results DROP CONSTRAINT IF EXISTS catalog_system_results_holds_withdrawn"
    )

    alter table(:catalog_pinned_builds) do
      remove(:firmware_judge)
      remove(:other_holds)
    end

    alter table(:catalog_system_results) do
      remove(:other_holds)
    end
  end
end
