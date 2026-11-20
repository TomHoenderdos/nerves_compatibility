defmodule Portal.Repo.Migrations.AddBuilderPublicationChanges do
  @moduledoc """
  `builders.publication_changes`: how many times the row's `publishing` or
  `status` changed, counted by a trigger on every update, whatever wrote it.
  `Portal.Catalog.precompiled_fingerprints/0` reads it in place of the row's
  `xmin` and `updated_at`, which every agent check-in changes
  (`Portal.Builders.touch/2`, about once a minute): by those, every batch
  rendered every package a remote builder built again. Publishing turned off
  and on again between two reads still reads as a change.

  Add-only for the release still running during the deploy window: it never
  names the column, and its writes pass through the trigger like any other.
  """

  use Ecto.Migration

  # ALTER TABLE takes an ACCESS EXCLUSIVE lock on a table the running release
  # writes on every agent check-in; a bounded wait fails the migration, and
  # the deploy, loudly instead of holding every writer behind it. A constant
  # default adds the column without rewriting the table.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:builders) do
      add(:publication_changes, :bigint, null: false, default: 0)
    end

    # Every update sets the count, so no writer can set it back.
    execute("""
    CREATE FUNCTION builders_count_publication_changes() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.publishing IS DISTINCT FROM OLD.publishing
         OR NEW.status IS DISTINCT FROM OLD.status THEN
        NEW.publication_changes := OLD.publication_changes + 1;
      ELSE
        NEW.publication_changes := OLD.publication_changes;
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER builders_count_publication_changes
    BEFORE UPDATE ON builders
    FOR EACH ROW EXECUTE FUNCTION builders_count_publication_changes()
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TRIGGER builders_count_publication_changes ON builders")
    execute("DROP FUNCTION builders_count_publication_changes()")

    alter table(:builders) do
      remove(:publication_changes)
    end
  end
end
