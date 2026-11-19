defmodule Portal.Repo.Migrations.AddPinnedBuilds do
  @moduledoc """
  Pinned builds (`Portal.Catalog.PinnedBuild`, lock-driven builds spec,
  section 3): a package version built against one closure from a project's
  `mix.lock`, served only in a version's `builds_closure` list.

    * `catalog_pinned_builds`, one row per (package, version, pin hash,
      target, system version, toolchain, builder version, config variant);
    * `catalog_artifact_memberships.pinned_build_id`, a fifth owner, with
      `one_owner` widened to the five;
    * `catalog_deterministic_builds.pinned_build_id`, a sibling's second
      possible owner: `toolchain_build_id` may now be NULL, and exactly one
      of the two is set (`one_build`).

  Add-only for the release still running during the deploy window: it
  never writes the new columns, so each of its membership rows keeps exactly
  one of its four owners and each of its siblings its toolchain build, and
  both satisfy the wider checks as they did the old ones. No existing index
  changes.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:catalog_pinned_builds, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(
        :package_id,
        references(:catalog_packages,
          column: :id,
          name: "catalog_pinned_builds_package_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:version, :text, null: false)
      add(:pin_hash, :text, null: false)
      add(:target, :text, null: false)
      add(:system_version, :text, null: false, default: "")
      add(:toolchain, :text, null: false)
      add(:builder_version, :bigint, null: false)
      add(:config_variant, :text, null: false, default: "default")
      add(:pins, :map, null: false)
      add(:status, :text, null: false)
      add(:reason, :text)

      for column <- [:elixir, :otp, :otp_full, :image_digest, :run_id, :package_checksum] do
        add(column, :text)
      end

      add(:builder_id, :uuid)
      add(:deps_lock, :map)
      add(:declared, {:array, :map})
      add(:compile_env, {:array, :map})
      add(:compile_env_rule, :bigint)
      add(:compile_inputs, {:array, :map})
      add(:file_manifest, :map)
      add(:optional_deps, :map)
      add(:native, :boolean)
      add(:portable, :boolean)
      add(:elf_needs, :map)
      add(:toolchain_pkg, :text)
      add(:toolchain_version, :text)
      add(:system_libs, :map)
      add(:judge_revision, :bigint)
      add(:portability_rule, :bigint)
      add(:rule1_reason, :text)
      add(:manager, :text)
      add(:compile_observations, :map)
      add(:reporters, :bigint, null: false, default: 0)
      add(:last_demand_at, :utc_datetime_usec)

      for column <- [:finished_at, :attempted_at, :revoked_at, :unpublished_at] do
        add(column, :utc_datetime_usec)
      end

      add(:revoked_reason, :text)
      add(:unpublished_reason, :text)

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
        :catalog_pinned_builds,
        [
          :package_id,
          :version,
          :pin_hash,
          :target,
          :system_version,
          :toolchain,
          :builder_version,
          :config_variant
        ],
        name: "catalog_pinned_builds_unique_identity_index"
      )
    )

    create(index(:catalog_pinned_builds, [:package_id, :version]))
    create(index(:catalog_pinned_builds, [:pin_hash]))
    create(index(:catalog_pinned_builds, [:run_id]))

    alter table(:catalog_artifact_memberships) do
      add(
        :pinned_build_id,
        references(:catalog_pinned_builds,
          column: :id,
          name: "catalog_artifact_memberships_pinned_build_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        )
      )
    end

    drop(constraint(:catalog_artifact_memberships, :one_owner))

    # NOT VALID, as `AddDeterministicBuilds` did: `AddPinnedMembershipIndexes`
    # builds the indexes concurrently and validates it outside any transaction.
    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check:
          "num_nonnulls(system_result_id, toolchain_build_id, host_native_build_id, " <>
            "deterministic_build_id, pinned_build_id) = 1",
        validate: false
      )
    )

    alter table(:catalog_deterministic_builds) do
      add(
        :pinned_build_id,
        references(:catalog_pinned_builds,
          column: :id,
          name: "catalog_deterministic_builds_pinned_build_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        )
      )
    end

    execute(
      "ALTER TABLE catalog_deterministic_builds ALTER COLUMN toolchain_build_id DROP NOT NULL"
    )

    create(
      constraint(:catalog_deterministic_builds, :one_build,
        check: "num_nonnulls(toolchain_build_id, pinned_build_id) = 1"
      )
    )

    create(
      unique_index(:catalog_deterministic_builds, [:pinned_build_id],
        name: "catalog_deterministic_builds_unique_pinned_build_index"
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DELETE FROM catalog_deterministic_builds WHERE pinned_build_id IS NOT NULL")
    drop(constraint(:catalog_deterministic_builds, :one_build))

    drop(
      index(:catalog_deterministic_builds, [:pinned_build_id],
        name: "catalog_deterministic_builds_unique_pinned_build_index"
      )
    )

    alter table(:catalog_deterministic_builds) do
      remove(:pinned_build_id)
    end

    execute("ALTER TABLE catalog_deterministic_builds ALTER COLUMN toolchain_build_id SET NOT NULL")
    execute("DELETE FROM catalog_artifact_memberships WHERE pinned_build_id IS NOT NULL")
    drop(constraint(:catalog_artifact_memberships, :one_owner))

    create(
      constraint(:catalog_artifact_memberships, :one_owner,
        check:
          "num_nonnulls(system_result_id, toolchain_build_id, host_native_build_id, " <>
            "deterministic_build_id) = 1"
      )
    )

    alter table(:catalog_artifact_memberships) do
      remove(:pinned_build_id)
    end

    drop(table(:catalog_pinned_builds))
  end
end
