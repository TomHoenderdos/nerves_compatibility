defmodule Portal.Catalog.ToolchainBuild do
  @moduledoc """
  One build of a pure-BEAM package version for one toolchain (Elixir minor /
  OTP major, e.g. `"1.19/28"`), for `Mix.install` users rather than Nerves
  targets.

  ## Why not a `Portal.Catalog.Run`

  Everything that shows a package's state reads its newest `Run`: package
  pages, stats, badges, and ingestion's carry of systems a partial run left
  out. A toolchain build is not a compatibility verdict for a Nerves target, so
  storing it as a run would let it become a package's "latest run" and replace
  real per-system results with a host-only build. Its own table keeps those
  readers unchanged.

  Its files are stored blobs like any run's (`Portal.Catalog.Artifact`), and
  `Portal.Catalog.ArtifactMembership` rows owned by this build record which
  blobs it produced.

  ## Variants

  A package compiles differently when one of its optional dependencies is
  loadable, and a client takes a build only when its lock agrees with the
  build's on them (decimal next to jason, or no decimal at all). So a version
  is built per `variant`: `:with` adds every optional dependency a fresh lock
  would (the worker's optional-dependency pass), `:without` leaves the pass
  out. `optional_deps` is what the worker reported doing, and a `:with` build
  that kept one is what makes the `:without` build wanted
  (`Portal.Catalog.toolchain_backlog/3`). A row written before variants
  existed was built the `:with` way, which is the default.

  ## Config variants

  A package that reads compile-time config compiles differently under the
  config a client's project sets, and a client takes a build only when its
  config agrees with the one the build was made in. So a version is also
  built per `config_variant`: `"default"` writes no config at all, and a
  `Compatibility.ConfigVariants` name (`"phx_prod"`, ...) has the worker
  write that variant's overlay as the project's config before compiling. A
  row written before config variants existed was built without an overlay,
  which is the default.

  The identity is `(package_id, version, toolchain, builder_version,
  variant, config_variant)`: a new build of the same inputs replaces the row
  (`:upsert`), and bumping `builder_version` keeps older builds side by side.
  Were the five-column index from before config variants recreated (a
  rollback), only the default could be stored again
  (`Portal.Catalog.ToolchainIdentity`).
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  @mutable [
    :status,
    :reason,
    :elixir,
    :otp,
    :image_digest,
    :run_id,
    :deps_lock,
    :package_checksum,
    :declared,
    :compile_env,
    :file_manifest,
    :optional_deps,
    :finished_at,
    :attempted_at,
    :portability_rule,
    :rule1_reason,
    :judge_revision,
    :compile_observations,
    :compile_env_rule,
    :transient_attempts
  ]

  @transient_cap 5
  @withheld_revocation "withheld closure"

  @doc """
  How many transient "could not be judged" builds in a row an identity gets
  at one builder version before it is left skipped (`Portal.Catalog.Ingestion`,
  `Portal.Catalog.toolchain_backlog/3`).
  """
  @spec transient_cap() :: pos_integer()
  def transient_cap, do: @transient_cap

  @doc """
  The `revoked_reason` of a build revoked because its closure has a withheld
  package (`Portal.Catalog.mark_withheld_revoked/2`).
  """
  @spec withheld_revocation() :: String.t()
  def withheld_revocation, do: @withheld_revocation

  postgres do
    table("catalog_toolchain_builds")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id, :version])
      index([:toolchain, :status])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :package_id,
        :version,
        :toolchain,
        :builder_version,
        :variant,
        :config_variant
        | @mutable
      ])

      validate({Portal.Catalog.ToolchainBuild.KnownConfigVariant, []})
      change(Portal.Catalog.ToolchainBuild.MarkRun)
    end

    create :upsert do
      accept([
        :package_id,
        :version,
        :toolchain,
        :builder_version,
        :variant,
        :config_variant
        | @mutable
      ])

      validate({Portal.Catalog.ToolchainBuild.KnownConfigVariant, []})
      change(Portal.Catalog.ToolchainBuild.MarkRun)
      upsert?(true)
      upsert_identity(:unique_config_identity)
      # Every mutable field, so a rebuild fully replaces the previous outcome:
      # a field the new build leaves nil (a cleared `reason`) must not survive.
      # `revoked_at` is deliberately absent: a rebuild does not un-revoke.
      upsert_fields([:compile_env_run_id | @mutable])
    end

    update :revoke do
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end

    # A rebuild of a re-opened identity that failed keeps the row it was
    # re-opened from (`Portal.Workers.ToolchainBuild`), and records that
    # attempt: the backlog re-opens a row by its last attempt, so the
    # identity then waits out its interval again rather than coming back next
    # sweep. `finished_at` stays the build's own, which the manifest serves.
    # The failure was not a transient "could not be judged", so it ends any
    # run of those: `transient_cap/0` counts them in a row, and the row goes
    # back to the weekly retry.
    update :retried do
      change(set_attribute(:attempted_at, &DateTime.utc_now/0))
      change(set_attribute(:transient_attempts, 0))
    end

    # A kept row whose rebuild came back as a transient "could not be judged":
    # the attempt counts towards `transient_cap/0`, and the backlog retries
    # it after a day rather than a week (`Portal.Catalog.toolchain_backlog/3`).
    update :retried_transient do
      accept([:transient_attempts])
      change(set_attribute(:attempted_at, &DateTime.utc_now/0))
    end

    # An operator's record that a revoked row was revoked for its withheld
    # closure (`Portal.Catalog.mark_withheld_revoked/2`), which the backlog
    # rebuilds once with its config reads recorded. Only a row that is
    # revoked: the reason never stands on a row that is still published.
    update :mark_withheld_revoked do
      change(set_attribute(:revoked_reason, @withheld_revocation))
      change(filter(expr(not is_nil(revoked_at))))
    end

    # The rebuild of a row revoked for its withheld closure recorded its
    # config reads, so the withheld list no longer applies to it. A row
    # revoked for any other reason stays revoked.
    update :unrevoke_rebuilt do
      change(filter(expr(revoked_reason == ^@withheld_revocation)))
      change(set_attribute(:revoked_at, nil))
      change(set_attribute(:revoked_reason, nil))
    end

    # Records what a row from before builds reported their optional
    # dependencies says about them (`Portal.Catalog.UnrecordedOptionalDeps`):
    # metadata only, so nothing a client is served changes. Only a row that
    # still reports nothing is written; a report that landed meanwhile is the
    # build's own and is kept.
    update :record_optional_deps do
      accept([:optional_deps])
      change(filter(expr(is_nil(optional_deps))))
    end
  end

  identities do
    identity(:unique_config_identity, [
      :package_id,
      :version,
      :toolchain,
      :builder_version,
      :variant,
      :config_variant
    ])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :version, :string do
      allow_nil?(false)
      public?(true)
    end

    # `"<elixir minor>/<otp major>"`, e.g. `"1.19/28"`.
    attribute :toolchain, :string do
      allow_nil?(false)
      public?(true)
    end

    # Version of the build procedure. Bumped when the way builds are made
    # changes, so new builds do not overwrite ones made the old way.
    attribute :builder_version, :integer do
      allow_nil?(false)
      public?(true)
    end

    # `:with` or `:without` the package's optional dependencies; see the
    # moduledoc.
    attribute :variant, :atom do
      allow_nil?(false)
      public?(true)
      default(:with)
      constraints(one_of: [:with, :without])
    end

    # The config variant (precompiled portability spec, R7) the build was
    # made in: "default" (no overlay) or a `Compatibility.ConfigVariants`
    # name, whose overlay the worker wrote as the project's config. Part of
    # the identity.
    attribute :config_variant, :string do
      allow_nil?(false)
      public?(true)
      default("default")
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:pass, :skipped, :error, :fail])
    end

    attribute :reason, :string do
      public?(true)
    end

    # Exact Elixir and OTP versions the build ran under.
    attribute :elixir, :string do
      public?(true)
    end

    attribute :otp, :string do
      public?(true)
    end

    attribute :image_digest, :string do
      public?(true)
    end

    # The worker's run id, linking the row to its build output.
    attribute :run_id, :string do
      public?(true)
    end

    # Same shape as `Portal.Catalog.Run.deps_lock`.
    attribute :deps_lock, :map do
      public?(true)
    end

    attribute :package_checksum, :string do
      public?(true)
    end

    # Same shape as `Portal.Catalog.Run.declared`.
    attribute :declared, {:array, :map} do
      public?(true)
    end

    attribute :compile_env, {:array, :map} do
      public?(true)
    end

    attribute :file_manifest, :map do
      public?(true)
    end

    # The worker's `optional_deps` report: `added`, `dropped`, `skipped` and
    # `reason`, as `result.json` has them.
    attribute :optional_deps, :map do
      public?(true)
    end

    # The precompiled verdict's rule. 1: `BuildSelection.portable?/4` AND the
    # compile-time trace's refusals (P1); nil for builds made before the
    # trace. Rule 2 is P4's.
    attribute :portability_rule, :integer do
      public?(true)
    end

    # What `portable?/4` alone said: its skip reason, nil when it passed.
    attribute :rule1_reason, :string do
      public?(true)
    end

    # The worker's judge revision (`NccWorker.Portability.judge_revision/1`)
    # the verdict was made under; nil for a build from before revisions and
    # for a host-side error row. The backlog reopens a `skipped` row below
    # its toolchain's newest revision once (`Portal.Catalog`,
    # `@judge_reopen`); `Portal.Precompiled.ToolchainRevocation` revokes by
    # it (`judge_revision:`).
    attribute :judge_revision, :integer do
      public?(true)
    end

    # What the compile-time trace observed (`NccWorker.Portability`),
    # bounded at ingest. The container's word; nothing re-judges it.
    attribute :compile_observations, :map do
      public?(true)
    end

    # 1 when `compile_env` also lists the compile-time config reads the
    # worker's trace observed across the package's closure (precompiled
    # portability spec, R5); nil when it is the `.app`'s list alone. Such a
    # build is exempt from the withheld list (`Portal.Precompiled.Withheld`).
    attribute :compile_env_rule, :integer do
      public?(true)
    end

    # The `run_id` of the write that set `compile_env_rule`, set in that
    # same write (`Portal.Catalog.ToolchainBuild.MarkRun`); nil with no
    # rule. The mark counts only while this is the row's own `run_id`
    # (`Portal.Precompiled.Withheld.records_config_reads?/1`): a release
    # that does not know this column replaces `run_id` and `compile_env` on
    # a rebuild and leaves both mark columns as they were.
    attribute :compile_env_run_id, :string do
      public?(true)
    end

    # Transient "could not be judged" results in a row for this identity
    # (`Portal.Catalog.Ingestion`); a build with a verdict resets it.
    attribute :transient_attempts, :integer do
      allow_nil?(false)
      default(0)
      public?(true)
    end

    # Why the row was revoked, when the backlog acts on it:
    # `withheld_revocation/0`.
    attribute :revoked_reason, :string do
      public?(true)
    end

    attribute :finished_at, :utc_datetime_usec do
      public?(true)
    end

    # When a failed rebuild last kept this row (the `:retried` action); nil
    # until then, and again once a rebuild replaces the row.
    attribute :attempted_at, :utc_datetime_usec do
      public?(true)
    end

    # Set by an admin to pull the build's files from publication, as
    # `Portal.Catalog.Run.revoked_at`.
    attribute :revoked_at, :utc_datetime_usec do
      public?(true)
    end

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
