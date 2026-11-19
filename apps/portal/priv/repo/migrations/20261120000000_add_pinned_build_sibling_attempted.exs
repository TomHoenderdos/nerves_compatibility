defmodule Portal.Repo.Migrations.AddPinnedBuildSiblingAttempted do
  @moduledoc """
  `catalog_pinned_builds.sibling_attempted`: whether the run that wrote a
  pinned build tried for its deterministic sibling, held or not
  (`Portal.Catalog.PinnedBuild`). `Portal.Pins.from_lock/2`'s
  `deterministic: true` builds a served pass without a sibling again only
  while this is false, so a closure is queued for its sibling once.

  Add-only for the release still running during the deploy window: its
  inserts take the default and its upserts leave the column alone, so every
  row it writes reads as no attempt, which costs at most one rebuild.
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
