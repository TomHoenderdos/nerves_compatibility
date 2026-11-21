defmodule Portal.Repo.Migrations.AddRelocatedFileManifest do
  @moduledoc """
  Relocated builds (S4): `relocated_file_manifest`, a relocated toolchain
  build's files, which its `file_manifest` (nil for it) would list for any
  other build. A release before S4 lists and serves a toolchain build's
  files from `file_manifest` alone, so it finds nothing to serve in a
  relocated row: in its listing, its files route and the earlier builds it
  writes when it rebuilds the row.

  Add-only for the release still running during the deploy window: a
  nullable column, no index, no default.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      add(:relocated_file_manifest, :map)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_toolchain_builds) do
      remove(:relocated_file_manifest)
    end
  end
end
