defmodule Portal.Repo.Migrations.AddFirmwareDriftAttempts do
  @moduledoc """
  `firmware_drift_attempts`: each firmware drift rebuild
  `Portal.Workers.ClosureDrift` queued, by the run it would replace and the
  fingerprint of its inputs (`Portal.Catalog.FirmwareDrift.Attempts`). A
  rebuild that landed no run leaves that run the package's latest, and the
  row is what keeps it from being queued again every day until its inputs
  change.

  A new table only: the release still running during the deploy window
  never reads or writes it.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:firmware_drift_attempts, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :run_id,
        references(:catalog_runs,
          column: :id,
          name: "firmware_drift_attempts_run_id_fkey",
          type: :uuid,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:package, :text, null: false)
      add(:version, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:systems, {:array, :text}, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:firmware_drift_attempts, [:run_id, :fingerprint]))
    create(index(:firmware_drift_attempts, [:package, :version]))
  end

  def down do
    drop(table(:firmware_drift_attempts))
  end
end
