defmodule Portal.Repo.Migrations.AddFirmwareWorldEnabled do
  @moduledoc """
  The `firmware_world_enabled` setting (`Portal.Settings`): whether a
  firmware build asks the worker for the `nerves` world build per passing
  target (`NCC_INPUT.firmware_world`). Off by default.
  """

  use Ecto.Migration

  # Add-only, with a constant default, as `AddWorldVariantsEnabled`: the
  # release still running during the deploy window keeps reading and
  # upserting settings without the column.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:firmware_world_enabled, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      remove(:firmware_world_enabled)
    end
  end
end
