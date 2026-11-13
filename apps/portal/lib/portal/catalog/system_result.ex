defmodule Portal.Catalog.SystemResult do
  @moduledoc """
  One row per (package × Nerves system × run). Replaces the entries of
  `latest_by_pkg_system.json`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  @rule2_revocation "rule 2 revoked"

  @doc """
  The `unpublished_reason` of a `pure_elixir` result
  `Portal.Precompiled.ToolchainRevocation` revoked, and of a later rule-2
  result of the same version ingest holds back for it.
  """
  @spec rule2_revocation() :: String.t()
  def rule2_revocation, do: @rule2_revocation

  postgres do
    table("catalog_system_results")
    repo(Portal.Repo)

    references do
      reference(:carried_from_run, on_delete: :nilify)
    end

    custom_indexes do
      index([:run_id])
      # Covers `Portal.Catalog.stats_json/0`'s GROUP BY, so counting every
      # result is an index-only scan rather than a pass over the blob-heavy
      # heap. It replaces an index on `(system_pkg, status)` that no query
      # filtered or grouped by. Partial, like the query: carried copies are
      # not counted.
      index([:system_pkg, :system_version, :status],
        name: "catalog_system_results_stats_index",
        where: "carried_from_run_id IS NULL"
      )
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :run_id,
        :system_pkg,
        :system_version,
        :status,
        :firmware_size_bytes,
        :duration_sec,
        :phase_timings,
        :hex_version_tested,
        :beam_scan,
        :compile_env,
        :compile_inputs,
        :dependency_scans,
        :log_path,
        :log_tail,
        :failure_category,
        :carried_from_run_id,
        :deps_lock,
        :compile_env_rule,
        :portability_rule,
        :unpublished_at,
        :unpublished_reason,
        :toolchain_pkg,
        :toolchain_version,
        :otp_full
      ])
    end

    update :update do
      accept([
        :status,
        :firmware_size_bytes,
        :duration_sec,
        :hex_version_tested,
        :beam_scan,
        :dependency_scans,
        :log_path,
        :failure_category
      ])
    end

    # What `Portal.Precompiled.ElfFacts.store_for/1` read from the result's
    # published priv files once their blobs were stored.
    update :store_elf_facts do
      accept([:native, :portable, :elf_needs])
    end

    # Withdraws this result's files from the precompiled API (spec section 7,
    # "One withheld rule"): its run, status and logs stay as they are. No
    # action undoes it; putting a result back is a deliberate SQL step.
    update :withdraw_publication do
      change(set_attribute(:unpublished_at, &DateTime.utc_now/0))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :system_pkg, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :system_version, :string do
      public?(true)
    end

    # Mirrors Compatibility.Types.status/0
    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:pass, :fail, :error, :skipped, :unknown])
    end

    attribute :firmware_size_bytes, :integer do
      public?(true)
    end

    # The worker has always reported this and nobody stored it, which left the
    # only per-target cost signal on the floor: a run compiles the same
    # dependency tree once per system, so knowing which system is expensive is
    # the whole basis for deciding what to cache or drop.
    attribute :duration_sec, :float do
      public?(true)
    end

    # `duration_sec` alone cannot say whether a shared build cache is worth
    # building: it lumps the dependency compile (cacheable) together with the
    # rootfs and image assembly (not cacheable). Keys: deps_sec, firmware_sec,
    # scan_sec (release_sec on runs from before the determinism pass was
    # dropped). A failed system carries deps_sec only.
    attribute :phase_timings, :map do
      public?(true)
    end

    attribute :hex_version_tested, :string do
      public?(true)
    end

    attribute :beam_scan, :map do
      public?(true)
    end

    # The `.app` file's compile_env reads as the worker recorded them:
    # `[%{"app", "path", "value"}]`, value a base64url deterministic term of
    # `{:ok, v}` or `:error`. Nil for results from images before it was
    # recorded or when the worker could not read the .app file.
    attribute :compile_env, {:array, :map} do
      public?(true)
    end

    # The compile-time inputs a client checks itself
    # (`Compatibility.CompileInputs`); nil before they were recorded, or when
    # the build's list was malformed (then `compile_env` is nil too).
    attribute :compile_inputs, {:array, :map} do
      public?(true)
    end

    # 1 when `compile_env` also lists the trace's compile-time config reads
    # (a published `pure_elixir` result, R5); nil otherwise. Exempts the
    # result from the withheld list. Carried copies keep it.
    attribute :compile_env_rule, :integer do
      public?(true)
    end

    # The precompiled portability rule that decided a `pure_elixir` result's
    # publication (result.json `host_portability.portability_rule`, 1..9), so
    # the results one rule published can be found again; nil on every other
    # system and on results ingested before it was recorded. Carried copies
    # keep it.
    attribute :portability_rule, :integer do
      public?(true)
    end

    attribute :dependency_scans, :map do
      public?(true)
    end

    # The package's transitive dependency closure as *this system's* build
    # locked it, same shape as `Run.deps_lock`. A firmware run's per-target
    # optional-dependency pass can recompile a passing target with the
    # package's optional deps added and republish that target's files with
    # them; when it does, the target's lock differs from the run's and this
    # is where it is recorded. Nil on every system that kept the run's own
    # build (every system before the pass existed, and any target the pass
    # did not touch or could not keep).
    attribute :deps_lock, :map do
      public?(true)
    end

    attribute :log_path, :string do
      public?(true)
    end

    attribute :log_tail, :string do
      public?(true)
    end

    attribute :failure_category, :string do
      public?(true)
    end

    # Set when the result's precompiled files were withdrawn; every
    # precompiled selector leaves it out (`Portal.Catalog`'s withheld clause
    # and `reject_withheld_results/4`, beside `Portal.Precompiled.Withheld`).
    # Carried copies keep it.
    attribute :unpublished_at, :utc_datetime_usec do
      public?(true)
    end

    # Which tool set `unpublished_at`: `rule2_revocation/0` for
    # `Portal.Precompiled.ToolchainRevocation`, nil for every other way, so
    # each tool lists and undoes only its own. Carried copies keep it.
    attribute :unpublished_reason, :string do
      public?(true)
    end

    # The toolchain the build's lock resolved for this system
    # (result.json `toolchain`, `%{"package", "version"}`) and the system
    # release's full OTP version (`otp_full`, e.g. "29.1.2"). Only on a
    # passing target build from an image that reports them; nil otherwise.
    attribute(:toolchain_pkg, :string, public?: true)
    attribute(:toolchain_version, :string, public?: true)
    attribute(:otp_full, :string, public?: true)

    # Read from the published priv files after ingest
    # (`Portal.Precompiled.ElfFacts`): whether any is ELF, whether every ELF
    # file reads as a loadable object whose needs are known, and those needs,
    # soname => sorted symbol versions. Nil when not computed: a host result,
    # a target without priv files, a blob that could not be read, or a
    # result ingested before they were recorded.
    attribute(:native, :boolean, public?: true)
    attribute(:portable, :boolean, public?: true)
    attribute(:elf_needs, :map, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :run, Portal.Catalog.Run do
      allow_nil?(false)
      public?(true)
    end

    # Set when a partial run (argus-only or a subset of targets) did not
    # rebuild this system and ingestion copied the result from an earlier
    # run. Points at the run that actually built it, so a chain of partial
    # runs does not lose where a result came from.
    belongs_to :carried_from_run, Portal.Catalog.Run do
      attribute_type(:uuid)
      allow_nil?(true)
      public?(true)
    end

    # Which stored blobs this system's manifest publishes. Points at the join
    # table, not at `Portal.Catalog.Artifact`: a blob is shared by every system
    # that produced those exact bytes, so the artifact registry has no owner
    # column to hang a `has_many` on.
    has_many :artifact_memberships, Portal.Catalog.ArtifactMembership do
      public?(true)
    end

    # Failures only, and never selected by the dashboard/badge/JSON queries —
    # those name their columns explicitly. Load it deliberately or not at all.
    has_one :system_log, Portal.Catalog.SystemLog do
      public?(true)
    end
  end
end
