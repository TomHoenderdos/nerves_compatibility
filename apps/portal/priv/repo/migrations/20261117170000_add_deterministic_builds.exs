defmodule Portal.Repo.Migrations.AddDeterministicBuilds do
  @moduledoc """
  Deterministic siblings (`Portal.Catalog.DeterministicBuild`): a toolchain
  build's own package compiled again with `ERL_COMPILER_OPTIONS=deterministic`
  in the same run, published only while the `deterministic_builds_enabled`
  setting is on, and only beside its served toolchain build.

    * `settings.deterministic_builds_enabled`, off by default;
    * `catalog_deterministic_builds`, at most one row per toolchain build,
      removed with it;
    * `catalog_artifact_memberships.deterministic_build_id`, a fourth owner,
      with `one_owner` widened to the four.

  Add-only for the release still running during the deploy window: it never
  writes the new column, so each of its membership rows keeps exactly one of
  its three owners and satisfies the wider `one_owner` as it did the old one,
  and its settings upsert names no new column.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:deterministic_builds_enabled, :boolean, null: false, default: false)
    end

    create table(:catalog_deterministic_builds, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :toolchain_build_id,
        references(:catalog_toolchain_builds,
          column: :id,
          name: "catalog_deterministic_builds_toolchain_build_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :package_id,
        references(:catalog_packages,
          column: :id,
          name: "catalog_deterministic_builds_package_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:version, :text, null: false)
      add(:run_id, :text, null: false)
      add(:status, :text, null: false)
      add(:reason, :text)
      add(:erl_compiler_options, {:array, :text}, null: false)
      add(:judge_revision, :bigint)
      add(:file_manifest, :map)
      add(:compile_observations, :map)
      add(:finished_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_reason, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      unique_index(:catalog_deterministic_builds, [:toolchain_build_id],
        name: "catalog_deterministic_builds_unique_toolchain_build_index"
      )
    )

    create(index(:catalog_deterministic_builds, [:package_id, :version]))

    alter table(:catalog_artifact_memberships) do
      add(
        :deterministic_build_id,
        references(:catalog_deterministic_builds,
          column: :id,
          name: "catalog_artifact_memberships_deterministic_build_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        )
      )
    end

    drop(constraint(:catalog_artifact_memberships, :one_owner))

    # NOT VALID, as `AddHostNativeBuilds` did: `AddDeterministicMembershipIndexes`
    # builds the indexes concurrently and validates it outside any transaction.
    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check:
          "num_nonnulls(system_result_id, toolchain_build_id, host_native_build_id, " <>
            "deterministic_build_id) = 1",
        validate: false
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DELETE FROM catalog_artifact_memberships WHERE deterministic_build_id IS NOT NULL")
    drop(constraint(:catalog_artifact_memberships, :one_owner))

    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check: "num_nonnulls(system_result_id, toolchain_build_id, host_native_build_id) = 1"
      )
    )

    alter table(:catalog_artifact_memberships) do
      remove(:deterministic_build_id)
    end

    drop(table(:catalog_deterministic_builds))

    alter table(:settings) do
      remove(:deterministic_builds_enabled)
    end
  end
end
