defmodule Portal.Repo.Migrations.AddWorldVariantsEnabled do
  @moduledoc """
  The `world_variants_enabled` setting (`Portal.Settings`): whether the
  toolchain backlog proposes world builds. Off by default.
  """

  use Ecto.Migration

  # Add-only, with a constant default, so the release still running during
  # the deploy window keeps reading and upserting settings without the
  # column. A bounded lock wait fails the migration, and the deploy, loudly
  # instead of queueing every settings writer behind a long read. SET LOCAL
  # lasts for the migration's own transaction only.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:world_variants_enabled, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      remove(:world_variants_enabled)
    end
  end
end
