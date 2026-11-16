defmodule Portal.Repo.Migrations.AddHostNativeBuilds do
  @moduledoc """
  Host-native builds (board #85, `Portal.Catalog.HostNativeBuild`): a NIF
  package built for one glibc Linux triple, published only while the
  `host_native_enabled` setting is on.

    * `settings.host_native_enabled`, off by default;
    * `catalog_host_native_builds`, one row per (package, version,
      toolchain, triple, builder version);
    * `catalog_artifact_memberships.host_native_build_id`, a third owner
      next to a system result and a toolchain build, with `one_owner`
      widened to the three.

  Add-only for the release still running during the deploy window: it never
  writes the new column, so each of its membership rows keeps exactly one of
  its two owners and satisfies the wider `one_owner` as it did the old one,
  and its settings upsert names no new column.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:host_native_enabled, :boolean, null: false, default: false)
    end

    create table(:catalog_host_native_builds, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :package_id,
        references(:catalog_packages,
          column: :id,
          name: "catalog_host_native_builds_package_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:version, :text, null: false)
      add(:toolchain, :text, null: false)
      add(:triple, :text, null: false)
      add(:builder_version, :bigint, null: false)
      add(:status, :text, null: false)
      add(:reason, :text)
      add(:elixir, :text)
      add(:otp, :text)
      add(:otp_full, :text)
      add(:nif_version, :text)
      add(:libc, :text)
      add(:glibc, :text)
      add(:image_digest, :text)
      add(:run_id, :text)
      add(:deps_lock, :map)
      add(:package_checksum, :text)
      add(:declared, {:array, :map})
      add(:compile_env, {:array, :map})
      add(:compile_env_rule, :bigint)
      add(:compile_inputs, {:array, :map})
      add(:file_manifest, :map)
      add(:native_files, {:array, :map})
      add(:origins, {:array, :map})
      add(:elf_needs, :map)
      add(:optional_deps, :map)
      add(:judge_revision, :bigint)
      add(:manager, :text)
      add(:compile_observations, :map)
      add(:finished_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)

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
      unique_index(
        :catalog_host_native_builds,
        [:package_id, :version, :toolchain, :triple, :builder_version],
        name: "catalog_host_native_builds_unique_identity_index"
      )
    )

    create(index(:catalog_host_native_builds, [:package_id, :version]))

    alter table(:catalog_artifact_memberships) do
      add(
        :host_native_build_id,
        references(:catalog_host_native_builds,
          column: :id,
          name: "catalog_artifact_memberships_host_native_build_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        )
      )
    end

    create(index(:catalog_artifact_memberships, [:host_native_build_id]))

    create(
      unique_index(:catalog_artifact_memberships, [:host_native_build_id, :sha256],
        name: "catalog_artifact_memberships_host_native_build_sha256_index"
      )
    )

    drop(constraint(:catalog_artifact_memberships, :one_owner))

    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check: "num_nonnulls(system_result_id, toolchain_build_id, host_native_build_id) = 1"
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DELETE FROM catalog_artifact_memberships WHERE host_native_build_id IS NOT NULL")
    drop(constraint(:catalog_artifact_memberships, :one_owner))

    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check: "num_nonnulls(system_result_id, toolchain_build_id) = 1"
      )
    )

    drop(
      index(:catalog_artifact_memberships, [:host_native_build_id, :sha256],
        name: "catalog_artifact_memberships_host_native_build_sha256_index"
      )
    )

    drop(index(:catalog_artifact_memberships, [:host_native_build_id]))

    alter table(:catalog_artifact_memberships) do
      remove(:host_native_build_id)
    end

    drop(table(:catalog_host_native_builds))

    alter table(:settings) do
      remove(:host_native_enabled)
    end
  end
end
