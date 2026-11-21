defmodule Portal.Repo.Migrations.AddRelocation do
  @moduledoc """
  Relocated builds (S4, `Portal.Precompiled.Relocated`): `relocation`, the
  worker's record of the occurrences of its deps and build paths a client
  rewrites at install (`Compatibility.Relocation`), and `relocation_run_id`,
  the run whose write set it, which counts only while that is the row's own
  `run_id`, on toolchain builds. And the `relocated_enabled` setting, off,
  whose changes `settings.publication_changes` counts beside the other
  settings a precompiled manifest depends on.

  Add-only for the release still running during the deploy window: its
  inserts leave the columns null and its upserts leave them alone, so a
  record an older release's rebuild left behind no longer has its row's
  `run_id` and counts for nothing. That release ingests a relocated pass as
  a skip with no files, so it never stores one as a plain pass.
  """

  use Ecto.Migration

  # ALTER TABLE takes an ACCESS EXCLUSIVE lock on a table the running release
  # keeps writing; a bounded wait fails the migration, and the deploy, loudly.
  # Nullable columns and a constant default add without rewriting a table.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      add(:relocation, :map)
      add(:relocation_run_id, :text)
    end

    alter table(:settings) do
      add(:relocated_enabled, :boolean, null: false, default: false)
    end

    execute(trigger(true))
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute(trigger(false))

    alter table(:settings) do
      remove(:relocated_enabled)
    end

    alter table(:catalog_toolchain_builds) do
      remove(:relocation_run_id)
      remove(:relocation)
    end
  end

  defp trigger(relocated?) do
    extra =
      if relocated?,
        do: "\n     OR NEW.relocated_enabled IS DISTINCT FROM OLD.relocated_enabled",
        else: ""

    """
    CREATE OR REPLACE FUNCTION settings_count_publication_changes() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.host_native_enabled IS DISTINCT FROM OLD.host_native_enabled
         OR NEW.deterministic_builds_enabled IS DISTINCT FROM OLD.deterministic_builds_enabled
         OR NEW.foreign_priv_enabled IS DISTINCT FROM OLD.foreign_priv_enabled#{extra} THEN
        NEW.publication_changes := OLD.publication_changes + 1;
      ELSE
        NEW.publication_changes := OLD.publication_changes;
      END IF;
      RETURN NEW;
    END
    $$
    """
  end
end
