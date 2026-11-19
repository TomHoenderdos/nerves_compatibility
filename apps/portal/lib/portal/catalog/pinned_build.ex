defmodule Portal.Catalog.PinnedBuild do
  @moduledoc """
  One pinned build (lock-driven builds spec, section 3): a package version
  compiled against exactly one closure from a project's `mix.lock`
  (`Compatibility.Pins`), on the toolchain path (`target` `"pure_elixir"`)
  in phase 1, and on one Nerves system's exact release (`nerves_system_*`,
  `system_version`) in phase 2.

  Neither a `Run` nor a `Portal.Catalog.ToolchainBuild` variant: a run
  becomes the package's latest run and moves `latest_version`, and a variant
  is an atom from a fixed list that every SQL reader of toolchain builds
  (backlog, closure drift, coverage, stats) reads. Nothing that reads runs
  or toolchain builds sees a pinned build, so it never shadows a default
  build, and it is served only in a version's `builds_closure` list
  (`Portal.Catalog.manifest_v2/1`), which only clients that compare the
  whole env closure read (0.7.0 and later, never a device).

  The identity is `(package_id, version, pin_hash, target, system_version,
  toolchain, builder_version, config_variant)`: a new build of the same key
  replaces the row (`:upsert`), and a `builder_version` bump keeps the old
  row beside the new one. `pins` is the set as requested and `deps_lock` the
  closure as built, equal to it on a pass (`Portal.Catalog.Ingestion`
  rechecks). Files are `Portal.Catalog.ArtifactMembership` rows owned by
  `pinned_build_id`; a deterministic sibling is a
  `Portal.Catalog.DeterministicBuild` owned by it.

  `revoked_at` withdraws one build (every revocation lever names it),
  `unpublished_at` a withdrawal by a count-first tool. `reporters` and
  `last_demand_at` are for demand (spec phase 3); the ABI columns (`native`,
  `portable`, `elf_needs`, `toolchain_pkg`, `toolchain_version`,
  `system_libs`, `otp_full`) for firmware builds (phase 2).
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  @identity [
    :package_id,
    :version,
    :pin_hash,
    :target,
    :system_version,
    :toolchain,
    :builder_version,
    :config_variant
  ]

  @mutable [
    :pins,
    :status,
    :reason,
    :elixir,
    :otp,
    :otp_full,
    :image_digest,
    :run_id,
    :builder_id,
    :deps_lock,
    :package_checksum,
    :declared,
    :compile_env,
    :compile_env_rule,
    :compile_inputs,
    :file_manifest,
    :optional_deps,
    :native,
    :portable,
    :elf_needs,
    :toolchain_pkg,
    :toolchain_version,
    :system_libs,
    :judge_revision,
    :portability_rule,
    :rule1_reason,
    :manager,
    :compile_observations,
    :finished_at
  ]

  @doc "The identity columns, in index order."
  @spec identity() :: [atom()]
  def identity, do: @identity

  postgres do
    table("catalog_pinned_builds")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id, :version])
      index([:pin_hash])
      index([:run_id])
    end

    identity_index_names(unique_identity: "catalog_pinned_builds_unique_identity_index")
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@identity ++ @mutable)
      upsert?(true)
      upsert_identity(:unique_identity)
      # A rebuild clears `attempted_at` with the verdict it replaces; it never
      # writes `revoked_at` or `unpublished_at`, so a withdrawal holds.
      upsert_fields(@mutable ++ [:attempted_at])
      change(set_attribute(:attempted_at, nil))
    end

    update :retried do
      change(set_attribute(:attempted_at, &DateTime.utc_now/0))
    end

    update :revoke do
      accept([:revoked_reason])
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_identity, @identity)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:pin_hash, :string, allow_nil?: false, public?: true)
    attribute(:target, :string, allow_nil?: false, public?: true)
    # `""` for `pure_elixir`, which has no system release.
    attribute :system_version, :string do
      allow_nil?(false)
      default("")
      constraints(allow_empty?: true, trim?: false)
      public?(true)
    end

    attribute(:toolchain, :string, allow_nil?: false, public?: true)
    attribute(:builder_version, :integer, allow_nil?: false, public?: true)
    attribute(:config_variant, :string, allow_nil?: false, default: "default", public?: true)
    attribute(:pins, :map, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:pass, :skipped, :error, :fail])
    end

    for name <- [:reason, :elixir, :otp, :otp_full, :image_digest, :run_id, :package_checksum] do
      attribute(name, :string, public?: true)
    end

    attribute(:builder_id, :uuid, public?: true)
    attribute(:deps_lock, :map, public?: true)
    attribute(:declared, {:array, :map}, public?: true)
    attribute(:compile_env, {:array, :map}, public?: true)
    attribute(:compile_env_rule, :integer, public?: true)
    attribute(:compile_inputs, {:array, :map}, public?: true)
    attribute(:file_manifest, :map, public?: true)
    attribute(:optional_deps, :map, public?: true)
    attribute(:native, :boolean, public?: true)
    attribute(:portable, :boolean, public?: true)
    attribute(:elf_needs, :map, public?: true)
    attribute(:toolchain_pkg, :string, public?: true)
    attribute(:toolchain_version, :string, public?: true)
    attribute(:system_libs, :map, public?: true)
    attribute(:judge_revision, :integer, public?: true)
    attribute(:portability_rule, :integer, public?: true)
    attribute(:rule1_reason, :string, public?: true)
    attribute(:manager, :string, public?: true)
    attribute(:compile_observations, :map, public?: true)
    attribute(:reporters, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:last_demand_at, :utc_datetime_usec, public?: true)

    for name <- [:finished_at, :attempted_at, :revoked_at, :unpublished_at] do
      attribute(name, :utc_datetime_usec, public?: true)
    end

    attribute(:revoked_reason, :string, public?: true)
    attribute(:unpublished_reason, :string, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :package, Portal.Catalog.Package do
      allow_nil?(false)
      public?(true)
    end

    has_many :artifact_memberships, Portal.Catalog.ArtifactMembership do
      public?(true)
    end
  end
end
