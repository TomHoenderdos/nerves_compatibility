defmodule Portal.Catalog.DeterministicBuild do
  @moduledoc """
  The deterministic sibling of one toolchain build (design addendum to
  option (a), `NccWorker.Deterministic`): the same package, closure and
  toolchain, compiled again in the same run with
  `ERL_COMPILER_OPTIONS=deterministic` and judged under the same rules. Its
  build fields (lock, checksum, compile env and inputs, manager) are its
  toolchain build's, which the worker and the ingest checked are equal
  (`Portal.Deterministic.Ingest`); only its files and its own trace's
  observations are its own.

  Its own table, never `Portal.Catalog.ToolchainBuild`'s: every reader of
  that table serves its rows to any client, and an old client would take a
  sibling in a project without the option. It is published only under a
  version's `deterministic` key, only while the `deterministic_builds_enabled`
  setting is on, and only beside its toolchain build while that build is
  served and of the run the sibling was built in (`Portal.Deterministic`):
  every lever that withdraws a toolchain build withdraws its sibling too.
  `revoked_at` withdraws the sibling alone
  (`Portal.Precompiled.DeterministicRevocation`).

  One row per toolchain build: an ingest that writes the toolchain build
  replaces its sibling, or removes it when the new run brought none. A
  pinned build (`Portal.Catalog.PinnedBuild`) has its sibling the same way,
  owned by `pinned_build_id` instead, and published only beside its served
  pinned build, in the `builds_closure` list of the version's
  `deterministic` key. A firmware target's sibling
  (`NccWorker.FirmwareDeterministic`) is owned by its system result
  (`system_result_id`, `run_id` the id of the result's `catalog_runs` row),
  written with the row by the
  run's ingest, and published only beside that row's own build while it is
  served. Exactly one of the three is set (`one_build`).
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_deterministic_builds")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id, :version])
    end

    identity_index_names(
      unique_toolchain_build: "catalog_deterministic_builds_unique_toolchain_build_index",
      unique_pinned_build: "catalog_deterministic_builds_unique_pinned_build_index",
      unique_system_result: "catalog_deterministic_builds_unique_system_result_index"
    )

    check_constraints do
      check_constraint(:toolchain_build_id, "one_build",
        check: "num_nonnulls(toolchain_build_id, pinned_build_id, system_result_id) = 1",
        message: "exactly one build"
      )
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :toolchain_build_id,
        :pinned_build_id,
        :system_result_id,
        :package_id,
        :version,
        :run_id,
        :status,
        :reason,
        :erl_compiler_options,
        :judge_revision,
        :file_manifest,
        :compile_observations,
        :finished_at
      ])
    end

    update :revoke do
      accept([:revoked_reason])
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_toolchain_build, [:toolchain_build_id])
    identity(:unique_pinned_build, [:pinned_build_id])
    identity(:unique_system_result, [:system_result_id])
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:run_id, :string, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:pass])
      public?(true)
    end

    attribute(:reason, :string, public?: true)

    attribute(:erl_compiler_options, {:array, :string}, allow_nil?: false, public?: true)

    attribute(:judge_revision, :integer, public?: true)
    attribute(:file_manifest, :map, public?: true)
    attribute(:compile_observations, :map, public?: true)
    attribute(:finished_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_reason, :string, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :toolchain_build, Portal.Catalog.ToolchainBuild do
      allow_nil?(true)
      public?(true)
    end

    belongs_to :pinned_build, Portal.Catalog.PinnedBuild do
      allow_nil?(true)
      public?(true)
    end

    belongs_to :system_result, Portal.Catalog.SystemResult do
      allow_nil?(true)
      public?(true)
    end

    belongs_to :package, Portal.Catalog.Package do
      allow_nil?(false)
      public?(true)
    end

    has_many :artifact_memberships, Portal.Catalog.ArtifactMembership do
      public?(true)
    end
  end
end
