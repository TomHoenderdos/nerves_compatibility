defmodule Portal.Repo.Migrations.AddPinLocks do
  @moduledoc """
  `catalog_pin_locks`: every project `mix.lock` an operator fed to
  `Portal.Pins.from_lock/2` with `dry_run: false` (stream S11), keyed by
  the sha256 of its content, with the options it was fed with (`system`,
  `toolchain`, `deterministic`) and the release of `system` it names
  (`release`). `refed` maps a system to the release
  `Portal.Workers.PinRefeed` last fed the lock again at, so a new system
  release queues its pinned firmware builds without an operator.

  A new table only: the release still running during the deploy window
  never reads or writes it.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create_if_not_exists table(:catalog_pin_locks, primary_key: false) do
      add(:sha256, :text, null: false, primary_key: true)
      add(:content, :text, null: false)
      add(:system, :text)
      add(:release, :text)
      add(:toolchain, :text)
      add(:deterministic, :boolean, null: false, default: false)
      add(:fed_at, :utc_datetime_usec, null: false)
      add(:refed, :map, null: false, default: %{})
    end

    create_if_not_exists(index(:catalog_pin_locks, [:system]))
  end

  def down do
    drop(table(:catalog_pin_locks))
  end
end
