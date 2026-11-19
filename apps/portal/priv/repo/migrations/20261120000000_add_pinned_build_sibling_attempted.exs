defmodule Portal.Repo.Migrations.AddPinnedBuildSiblingAttempted do
  @moduledoc """
  `catalog_pinned_builds.sibling_attempted`: whether a pinned build's
  deterministic sibling was tried for, held or not, by its run or by a
  sibling backfill (`Portal.Catalog.PinnedBuild`). `Portal.Pins.from_lock/2`'s
  `deterministic: true` queues a served pass without a sibling only while
  this is false, and sets it when it does, so a closure is queued for its
  sibling once.

  Add-only for the release still running during the deploy window: its
  inserts take the default and its upserts leave the column alone, so a
  mark stays and a row it inserts reads as no attempt.
  """

  use Ecto.Migration

  # ALTER TABLE takes an ACCESS EXCLUSIVE lock on a table the running
  # release keeps writing; a bounded wait fails the migration, and the
  # deploy, loudly instead of holding every writer behind it. A constant
  # default adds the column without rewriting the table.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_pinned_builds) do
      add(:sibling_attempted, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_pinned_builds) do
      remove(:sibling_attempted)
    end
  end
end
