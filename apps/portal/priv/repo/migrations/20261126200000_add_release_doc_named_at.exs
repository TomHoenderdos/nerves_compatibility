defmodule Portal.Repo.Migrations.AddReleaseDocNamedAt do
  @moduledoc """
  S10 round 5 re-review R5-5: `precompiled_release_docs.named_at`, when a
  batch last named the document (`Portal.Catalog.ReleaseIndex.store_docs/1`
  refreshes it at most hourly). A document no batch named for three days,
  well past a batch's 24 h expiry, is deleted. Add-only, on a table no
  deployed release reads.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:precompiled_release_docs) do
      add_if_not_exists(:named_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end

  def down do
    alter table(:precompiled_release_docs) do
      remove_if_exists(:named_at, :utc_datetime_usec)
    end
  end
end
