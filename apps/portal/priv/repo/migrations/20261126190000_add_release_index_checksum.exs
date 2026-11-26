defmodule Portal.Repo.Migrations.AddReleaseIndexChecksum do
  @moduledoc """
  S10 round 5 re-review F2: `catalog_release_index.outer_checksum`, the
  registry's outer checksum of the tarball a read release's modules came
  from. Hex lets a public release be replaced within an hour of publication
  (`mix hex.publish --replace`): the index reads a recently read release
  again when the registry's checksum differs, and the batch's read shards
  list `[version, outer_checksum]`, which a client compares with its lock.
  Add-only and nullable, on a table no deployed release reads.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:catalog_release_index) do
      add_if_not_exists(:outer_checksum, :text)
    end
  end

  def down do
    alter table(:catalog_release_index) do
      remove_if_exists(:outer_checksum, :text)
    end
  end
end
