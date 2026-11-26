defmodule Portal.Repo.Migrations.AddReleaseIndex do
  @moduledoc """
  S10 round 5, the module index per release (`Portal.Catalog.ReleaseIndex`):

    * `catalog_release_index`: every Hex release the index tried, by
      package and version, `read` (its modules stored) or `failed` (with
      why), and its application;
    * `catalog_release_definers`: each module a read release defines (its
      compiled sources, and the modules our passing builds of it wrote);
    * `catalog_release_probed_modules`: the modules a served build's
      declared `probe` item names, which each batch renders a definer set
      for;
    * `precompiled_release_docs`: the content-addressed documents a batch
      names under `release_index` (the read releases in 256 shards, and one
      definer set per probed module), served by sha.

  New tables only: the release still running during the deploy window never
  reads or writes them.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create_if_not_exists table(:catalog_release_index, primary_key: false) do
      add(:package, :text, null: false, primary_key: true)
      add(:version, :text, null: false, primary_key: true)
      add(:state, :text, null: false)
      add(:reason, :text)
      add(:app, :text)
      add(:modules, :integer, null: false, default: 0)
      add(:tried_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists table(:catalog_release_definers, primary_key: false) do
      add(:module, :text, null: false, primary_key: true)
      add(:package, :text, null: false, primary_key: true)
      add(:version, :text, null: false, primary_key: true)
    end

    create_if_not_exists(index(:catalog_release_definers, [:package, :version]))

    create_if_not_exists table(:catalog_release_probed_modules, primary_key: false) do
      add(:module, :text, null: false, primary_key: true)
      add(:first_seen_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists table(:precompiled_release_docs, primary_key: false) do
      add(:sha256, :text, null: false, primary_key: true)
      add(:body, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end
  end

  def down do
    drop(table(:precompiled_release_docs))
    drop(table(:catalog_release_probed_modules))
    drop(table(:catalog_release_definers))
    drop(table(:catalog_release_index))
  end
end
