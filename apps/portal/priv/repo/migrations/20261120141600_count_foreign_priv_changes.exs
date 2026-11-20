defmodule Portal.Repo.Migrations.CountForeignPrivChanges do
  @moduledoc """
  `settings.publication_changes` counts changes to `foreign_priv_enabled`
  too (foreign priv spec 4.3): the setting decides whether a version's
  `foreign_priv` object and kino's own builds render, so it is a setting a
  precompiled manifest depends on, beside `host_native_enabled` and
  `deterministic_builds_enabled`. `Portal.Catalog.precompiled_fingerprints/0`
  reads the count for kino and every package with a foreign priv build: by
  value alone, the setting turned on and off again between a batch's two
  fingerprint reads would read as no change, and the batch would remember a
  manifest rendered while it was on.

  Replaces the trigger function `AddSettingsPublicationChanges` made, which
  takes no lock on the table. Add-only for the release still running during
  the deploy window: it never names the column it counts, and its writes
  pass through the trigger like any other, leaving that column as it was.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION settings_count_publication_changes() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.host_native_enabled IS DISTINCT FROM OLD.host_native_enabled
         OR NEW.deterministic_builds_enabled IS DISTINCT FROM OLD.deterministic_builds_enabled
         OR NEW.foreign_priv_enabled IS DISTINCT FROM OLD.foreign_priv_enabled THEN
        NEW.publication_changes := OLD.publication_changes + 1;
      ELSE
        NEW.publication_changes := OLD.publication_changes;
      END IF;
      RETURN NEW;
    END
    $$
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION settings_count_publication_changes() RETURNS trigger
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
  end
end
