defmodule Portal.Repo.Migrations.AddForeignPriv do
  @moduledoc """
  Foreign priv builds (foreign priv spec 4.1): `foreign_priv`, the archives a
  build's compile wrote into kino's priv as the worker listed them and the
  host re-proved them; `foreign_priv_rule`; and `foreign_priv_run_id`, the
  run whose write set the list, which counts only while that is the row's
  own `run_id` (`Portal.Precompiled.ForeignPriv.counted/1`), on toolchain,
  pinned and deterministic builds. And the `foreign_priv_enabled` setting,
  off.

  Add-only for the release still running during the deploy window: its
  inserts leave the columns null and its upserts leave them alone, so a list
  an older release's rebuild left behind no longer has its row's `run_id`
  and counts for nothing.
  """

  use Ecto.Migration

  @tables [:catalog_toolchain_builds, :catalog_pinned_builds, :catalog_deterministic_builds]

  # ALTER TABLE takes an ACCESS EXCLUSIVE lock on tables the running release
  # keeps writing; a bounded wait fails the migration, and the deploy,
  # loudly instead of holding every writer behind it. Nullable columns and a
  # constant default add without rewriting a table.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    for table <- @tables do
      alter table(table) do
        add(:foreign_priv, {:array, :map})
        add(:foreign_priv_rule, :text)
        add(:foreign_priv_run_id, :text)
      end
    end

    alter table(:settings) do
      add(:foreign_priv_enabled, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      remove(:foreign_priv_enabled)
    end

    for table <- @tables do
      alter table(table) do
        remove(:foreign_priv_run_id)
        remove(:foreign_priv_rule)
        remove(:foreign_priv)
      end
    end
  end
end
