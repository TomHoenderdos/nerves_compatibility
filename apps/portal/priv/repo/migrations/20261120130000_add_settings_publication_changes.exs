defmodule Portal.Repo.Migrations.AddSettingsPublicationChanges do
  @moduledoc """
  `settings.publication_changes`: how many times the row's
  `host_native_enabled` or `deterministic_builds_enabled` changed, counted by
  a trigger on every update, whatever wrote it. They are the only settings a
  precompiled manifest depends on, and
  `Portal.Catalog.precompiled_fingerprints/0` reads the count for every
  package with a host-native or deterministic row: by value alone, a setting
  turned on and off again between a batch's two fingerprint reads would read
  as no change, and the batch would remember a manifest rendered while it was
  on. Not the row's `xmin`: `remote_auto_on` is written from the enqueue path,
  and would render those packages again in every batch.

  Add-only for the release still running during the deploy window: it never
  names the column, and its writes pass through the trigger like any other.
  """

  use Ecto.Migration

  # ALTER TABLE takes an ACCESS EXCLUSIVE lock on a table the running release
  # reads on most paths; a bounded wait fails the migration, and the deploy,
  # loudly instead of holding every reader behind it. A constant default adds
  # the column without rewriting the table.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:publication_changes, :bigint, null: false, default: 0)
    end

    # Every update sets the count, so no writer can set it back.
    execute("""
    CREATE FUNCTION settings_count_publication_changes() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.host_native_enabled IS DISTINCT FROM OLD.host_native_enabled
         OR NEW.deterministic_builds_enabled IS DISTINCT FROM OLD.deterministic_builds_enabled THEN
        NEW.publication_changes := OLD.publication_changes + 1;
      ELSE
        NEW.publication_changes := OLD.publication_changes;
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER settings_count_publication_changes
    BEFORE UPDATE ON settings
    FOR EACH ROW EXECUTE FUNCTION settings_count_publication_changes()
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TRIGGER settings_count_publication_changes ON settings")
    execute("DROP FUNCTION settings_count_publication_changes()")

    alter table(:settings) do
      remove(:publication_changes)
    end
  end
end
