defmodule Portal.Catalog.Ingestion do
  @moduledoc """
  Ingests a parsed worker `result.json` into the `Portal.Catalog` domain.

  The builder Oban job is the only writer of catalog data. One successful build
  becomes:

    * an upserted `Package` (by name; refreshes `latest_version`/`last_run_at`)
    * one `Run` (the envelope of `result.json`)
    * N × `SystemResult` (one per system in `result.systems`)
    * M × `Artifact` (content-addressed blobs moved out of the build's
      `files_dir` into the `Portal.ArtifactStore`)

  `overall_status` is derived from the per-system statuses (or a top-level
  `forced_status` when the worker emitted one).

  Blobs are moved and build logs are read *before* the transaction opens; only
  the row inserts run inside it. See `ingest/2`.

  ## The job's identity

  Every caller says what the job was enqueued for: `:package` and `:version`,
  and for `ingest_toolchain/2` `:toolchain`, `:variant` (`:with` when
  absent) and `:config_variant` (`"default"` when absent) as well. Ingest checks the result
  against the job it was enqueued for: when `result.json` names another
  package, version or toolchain, nothing is staged or written and the call
  returns `{:error, {:identity_mismatch, job, result}}`, each side a map of
  `:package`, `:version` and, for a toolchain build, `:toolchain`. When they
  agree, the rows are written under the job's identity.

  The identity is required on every path: a call without it, or with a blank
  one, returns `{:error, {:identity_missing, keys}}` naming the missing keys,
  again before anything is staged or written. The result's own identity is
  never used in its place. `Portal.Workers.Ingest` passes the identity its
  job carries (for a remote build, its lease's), and the portal's own
  synthesized results (`Portal.Catalog.RegistryAssessment`,
  `Portal.Catalog.ToolingSkip`) pass the package and version they record.

  The worker's top-level `process_sweep` field is the container's own account
  of its process sweep, for monitoring only, and is not read here: a sweep
  that failed shows in the per-system statuses and the toolchain verdict.
  """

  require Logger
  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias Compatibility.CompileInputs
  alias Compatibility.ConfigVariants
  alias Portal.ArtifactStore

  alias Portal.Catalog.{
    Artifact,
    ArtifactMembership,
    FindingTriage,
    LatestRun,
    LogSanitizer,
    Package,
    PinnedBuild,
    Run,
    SystemAbi,
    SystemLog,
    SystemResult,
    ToolchainBuild,
    ToolchainForeignPriv,
    ToolchainPriv
  }

  alias Portal.Catalog.ToolchainBuild.EarlierBuilds

  alias Portal.Precompiled.{ElfFacts, FirmwareRefusal, Withheld}
  alias Portal.Repo

  @domain Portal.Catalog

  # The keys of a stored file manifest, each the top directory its entries'
  # paths sit under.
  @manifest_keys ["ebin", "priv"]

  # Results built on the host, not for a Nerves system: no target ELF facts.
  @host_systems ["host", "pure_elixir"]

  # The config variant of every build without an overlay.
  @default_config_variant ConfigVariants.default()

  # The worker caps argus findings at 200, so one batch covers a whole run.
  @max_triage_batch 200

  # An ingest writes a handful of rows, but each one crosses a ~80ms private network
  # link from the build box to Postgres. DBConnection's 15s default leaves no
  # headroom for a loaded builder; 60s does, without hiding a real hang.
  @transaction_timeout 60_000

  # Scopes a failed log insert to itself. See `insert_log/3`.
  @log_savepoint "ncc_system_log"

  @type ingest_opts :: %{
          required(:run_id) => String.t(),
          required(:image_digest) => String.t(),
          required(:files_dir) => Path.t(),
          optional(:output_dir) => Path.t() | nil,
          optional(:scan_request_id) => String.t() | nil,
          optional(:builder_id) => String.t() | nil,
          optional(:arch) => String.t() | nil,
          # The firmware world the build job asked for (`"nerves"`), nil for
          # none: a `world_<name>` variant is kept only when the result
          # echoes it (`firmware_world/2`).
          optional(:firmware_world) => String.t() | nil,
          optional(:log) => String.t() | nil,
          # Stage the logs of these systems only; every failed one when absent.
          optional(:log_systems) => [String.t()] | nil,
          # Set only by `Portal.Catalog.BuildTimeout`, never from a result:
          # a partial run keeps the previous run's footprint and argus result.
          optional(:carry_run_data) => boolean(),
          # Tests only: replaces the query for the run's results to read as
          # ELF after commit, to show a failure there cannot fail the ingest.
          optional(:elf_candidates) => (Ecto.UUID.t() -> [map()]),
          required(:package) => String.t(),
          required(:version) => String.t()
        }

  @type toolchain_opts :: %{
          required(:run_id) => String.t(),
          required(:image_digest) => String.t(),
          required(:files_dir) => Path.t(),
          required(:toolchain) => String.t(),
          required(:builder_version) => pos_integer(),
          required(:package) => String.t(),
          required(:version) => String.t(),
          optional(:output_dir) => Path.t() | nil,
          optional(:variant) => atom(),
          optional(:config_variant) => String.t(),
          optional(:hex_outer_checksum) => (String.t(), String.t() -> term()),
          optional(:hex_tarball) => (String.t(), String.t() -> term())
        }

  @typedoc "What a job asked to build, or what a result says was built."
  @type identity :: %{
          required(:package) => String.t() | nil,
          required(:version) => String.t() | nil,
          optional(:toolchain) => String.t() | nil,
          optional(:variant) => :with | :without | term(),
          optional(:config_variant) => String.t()
        }

  @doc """
  Ingest a parsed `result.json` map. Returns `{:ok, run}` or `{:error, reason}`.

  Two phases. Blobs are moved out of `files_dir` into the artifact store first,
  with no database connection held; the rows they produce are then written in
  one transaction.

  Both phases used to share the transaction. Moving the blobs costs a `mkdir` +
  `stat` + `rename` + `chmod` per file, on the order of a thousand files per
  system and four systems per run, on a box already saturated by buildroot. That
  ran past DBConnection's 15s checkout limit, so DBConnection killed the
  connection out from under the ingest and every large package failed with
  `tcp recv: closed`. Filesystem work does not belong in a transaction.

  `opts` must carry the job's `:package` and `:version`, and the result must
  name the same package and version (see "The job's identity" above), both
  checked before anything is staged.
  """
  @spec ingest(map(), ingest_opts()) ::
          {:ok, Run.t()}
          | {:error,
             {:identity_mismatch, identity(), identity()}
             | {:identity_missing, [atom()]}
             | term()}
  def ingest(result, opts) when is_map(result) do
    with :ok <- check_identity(result, opts, [:package, :version]) do
      stage_and_write_run(result, opts)
    end
  end

  defp stage_and_write_run(result, opts) do
    systems = Map.get(result, "systems", %{})
    # Checked first: the checks read the targets' blobs from the run's files.
    siblings = firmware_siblings(systems, opts)
    staged = stage_artifacts(systems, opts.files_dir)

    siblings =
      Map.new(siblings, fn {pkg, candidate} -> {pkg, stage_sibling(candidate, opts, pkg)} end)

    logs = systems |> log_systems(opts) |> stage_logs(Map.get(opts, :output_dir))

    Repo.transaction(
      fn ->
        case do_ingest(result, opts, {staged, siblings}, logs) do
          {:ok, run} -> run
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @transaction_timeout
    )
    |> tap(fn
      {:ok, run} ->
        best_effort("record the system ABI facts of run", run.id, fn ->
          record_system_abi(run, systems, Map.get(opts, :elf_candidates, &elf_candidates/1))
        end)

      _error ->
        :ok
    end)
  end

  # After the rows are committed, and best-effort: what a target build says
  # about its system release, and what its published priv files are as ELF,
  # are facts for matching builds across releases, never a reason to fail an
  # ingest that already wrote the run: the caller runs this whole step under
  # `best_effort/3`, so nothing it raises, throws or exits with reaches
  # `ingest/2`'s return value.
  defp record_system_abi(run, systems, elf_candidates) do
    Enum.each(systems, fn {system_pkg, sys} ->
      best_effort("observe", system_pkg, fn -> observe_release(system_pkg, sys) end)
    end)

    run.id
    |> elf_candidates.()
    |> Enum.each(fn %{id: id, system_pkg: system_pkg} ->
      best_effort("read the ELF facts of", system_pkg, fn -> store_elf_facts(id, system_pkg) end)
    end)
  end

  defp store_elf_facts(system_result_id, system_pkg) do
    case ElfFacts.store_for(system_result_id) do
      {:ok, _row} -> :ok
      {:error, reason} -> warn_abi("read the ELF facts of", system_pkg, reason)
    end
  end

  defp observe_release(system_pkg, %{"system_version" => version} = sys)
       when is_binary(version) and
              (is_map_key(sys, "toolchain") or is_map_key(sys, "system_libs")) do
    {toolchain_pkg, toolchain_version} = system_toolchain(sys["toolchain"])

    observation = %{
      system_pkg: system_pkg,
      version: version,
      toolchain_pkg: toolchain_pkg,
      toolchain_version: toolchain_version,
      otp: fact_string(sys["otp_full"]),
      libs: sys["system_libs"],
      source: "lock"
    }

    case SystemAbi.observe(observation) do
      {:ok, _row} -> :ok
      {:error, reason} -> warn_abi("observe", system_pkg, reason)
    end
  end

  defp observe_release(_system_pkg, _sys), do: :ok

  # This run's own target results that publish a file manifest (an `ebin`
  # list; an empty priv makes them beam-only); host results and
  # carried copies (which keep the facts of the run that built them) are left
  # out.
  defp elf_candidates(run_id) do
    Repo.all(
      from(s in "catalog_system_results",
        where: s.run_id == type(^run_id, Ecto.UUID),
        where: is_nil(s.carried_from_run_id),
        where: s.system_pkg not in ^@host_systems,
        where:
          fragment(
            "jsonb_typeof(? #> '{footprint,file_manifest,ebin}') = 'array'",
            s.beam_scan
          ),
        select: %{id: type(s.id, Ecto.UUID), system_pkg: s.system_pkg}
      )
    )
  end

  defp best_effort(what, subject, fun) do
    fun.()
    :ok
  rescue
    error -> warn_abi(what, subject, Exception.message(error))
  catch
    kind, reason -> warn_abi(what, subject, {kind, reason})
  end

  defp warn_abi(what, subject, reason) do
    Logger.warning("Could not #{what} #{inspect(subject)}: #{inspect(reason)}")
  end

  defp system_toolchain(%{"package" => package, "version" => version}),
    do: {fact_string(package), fact_string(version)}

  defp system_toolchain(_toolchain), do: {nil, nil}

  # A short string from result.json, or nil.
  defp fact_string(value) when is_binary(value) and byte_size(value) in 1..200, do: value
  defp fact_string(_value), do: nil

  # Checks the result against the job's identity, which the caller must
  # pass in full. A result that names no package at all is not checked here:
  # `do_ingest/4` and `do_ingest_toolchain/4` raise on it, as they always
  # have, and the worker retries it like any other unmappable result.
  defp check_identity(result, opts, keys) do
    case Enum.reject(keys, &present?(Map.get(opts, &1))) do
      [] -> check_reported(result, Map.new(keys, &{&1, Map.fetch!(opts, &1)}), keys)
      missing -> {:error, {:identity_missing, missing}}
    end
  end

  defp check_reported(result, job, keys) do
    case result_identity(result, keys) do
      %{package: nil} -> :ok
      ^job -> :ok
      reported -> {:error, {:identity_mismatch, job, reported}}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp result_identity(result, keys) do
    package = Map.get(result, "package")
    package = if is_map(package), do: package, else: %{}
    build = Map.get(result, "toolchain_build")
    build = if is_map(build), do: build, else: %{}

    %{
      package: package["name"],
      version: package["version"],
      toolchain: Portal.Toolchains.from_versions(build["elixir"], build["otp"])
    }
    |> Map.take(keys)
  end

  @doc """
  Ingest the `result.json` of a `"toolchain"` run (`scope: "toolchain"`) into one
  `Portal.Catalog.ToolchainBuild`. Returns `{:ok, toolchain_build}` or
  `{:error, reason}`.

  No `Run` is written and the package's `last_run_at` and `latest_version` stay
  as they are: a toolchain build is not a compatibility verdict for a Nerves
  target, and every page reads the newest run as one (see `ToolchainBuild`).
  The package row is only created when the catalog has none yet.

  The blobs named in `toolchain_build.file_manifest` are moved into the artifact
  store first, outside the transaction, as `ingest/2` does. The row is then
  upserted on `(package, version, toolchain, builder_version, variant,
  config_variant)`, and its
  memberships are made to match this build's manifest exactly: a rebuild that
  stops passing, or produces other files, must not keep publishing the old ones.

  `opts.version` is the version the job was queued for, which keys the row so
  it matches the sweep's backlog.

  `opts` must carry the job's `:package`, `:version` and `:toolchain`; the
  result must name the same package and version, and its `toolchain_build`'s
  `elixir` and `otp` must be the job's `toolchain`
  (`Portal.Toolchains.from_versions/2`), all checked before anything is
  staged (see "The job's identity" above).

  `opts.variant` is the optional-deps variant the job built (`:with` when
  absent, for an ingest job enqueued before variants existed) and is part of
  its identity: a result that says it was built as the other variant (its
  `requested_optional_deps` echo, or, without one, an `optional_deps.reason`
  of `"not_requested"`, which only a build without them reports) is refused
  with `{:error, {:identity_mismatch, job, result}}`, both sides carrying
  `:variant`. A result that states no variant is held to a `:with` job; a
  `:without` job refuses it (its `:variant` nil), since a worker from before
  variants ignores the request and adds the optional dependencies anyway, and
  refuses one that reports an added optional dependency whatever it echoes
  (its `:variant` `:with`). The result's `optional_deps` report is stored on
  the row as it is.

  `opts.config_variant` is the config variant the job built (`"default"`
  when absent, for an ingest job enqueued before config variants existed),
  the row's `config_variant`, and part of its identity too: a result whose
  `toolchain_build.config_variant` (`"default"` when absent, as a worker
  that does not know the request reports nothing) differs is refused with
  `{:error, {:identity_mismatch, job, result}}`, both sides carrying
  `:config_variant`. The job's value is the one stored, never the echo. A
  named variant's `pass` is published only when it shows its overlay was in
  effect: marked (`compile_env_rule` 1 next to a kept `compile_env`) and
  every overlay key it recorded at the overlay's value
  (`Compatibility.ConfigVariants.overlay_recorded/2`). Otherwise it is
  stored as `skipped`, with that reason ("config variant records no config
  reads", or the one `overlay_recorded/2` gives) and no files.

  A later `skipped` verdict for the same identity, a refusal included,
  overwrites a pass row, and its memberships with it. An `:error`, a build
  that gave no verdict, never does: a pass or skipped row of the same identity
  is kept with its files, and records the attempt (`attempted_at`), as
  `Portal.Workers.ToolchainBuild` keeps it for a failed job. Nor does a
  failed compile: the same version on the same image compiled before, so a
  compile that now fails is the environment's, and the pass row is kept the
  same way, unless it is revoked. A `fail` the host refuses a build with
  still replaces it.

  A `skipped` build whose reason is "portability could not be judged" and
  whose trace says that was transient
  (`compile_observations.trace_stats.transient`: the traced compile did not
  finish, or its report was over the read budget) is stored as an `:error`,
  which the backlog retries after a day, and counted in
  `transient_attempts`; the `ToolchainBuild.transient_cap/0`-th in a row is
  stored as `skipped` ("portability could not be judged (transient N
  times)"), which the backlog leaves alone at this builder version. A kept
  `pass` or `skipped` row counts it too, and is retried after a day while
  under the cap. Any build with a verdict resets the count. A could-not-judge
  the package causes again on every run, or one from a worker that does not
  report `transient`, stays `skipped`.

  Another `:error` neither counts nor resets an `:error` row's count; on a
  kept row it ends the run of transient results and resets it, as a `fail`
  does. Every ingest of one identity
  takes a transaction lock on it first (`lock_toolchain_identity/1`), so two
  ingests of the same identity at once cannot both read one count.

  A pass build with priv files is checked on the host first
  (`Portal.Catalog.ToolchainPriv`, which `opts.hex_outer_checksum` and
  `opts.hex_tarball` feed). A refused build is stored as a `fail` with the
  reason and no files at all; a check Hex could not answer returns
  `{:error, reason}` before anything is written, for the job to retry.
  """
  @spec ingest_toolchain(map(), toolchain_opts()) ::
          {:ok, ToolchainBuild.t()}
          | {:error,
             {:identity_mismatch, identity(), identity()}
             | {:identity_missing, [atom()]}
             | term()}
  def ingest_toolchain(result, opts) when is_map(result) do
    keys = [:package, :version, :toolchain]

    with :ok <- check_identity(result, opts, keys),
         :ok <- check_variant(result, opts, keys),
         :ok <- check_config_variant(result, opts, keys) do
      stage_toolchain_build(result, opts)
    end
  end

  @doc """
  Ingest the `result.json` of a pinned toolchain build (`NCC_INPUT.pins`,
  `NccWorker.Pins`) into one `Portal.Catalog.PinnedBuild`, through the same
  staging and gates a toolchain build goes through (`ingest_toolchain/2`):
  the identity check, the config variant, the misplaced-entry and priv
  checks on the host (`Portal.Catalog.ToolchainPriv`), the verdict mapping
  (a failed compile is a `fail`, a transient could-not-judge an `error`),
  every file staged or none, and the deterministic sibling
  (`Portal.Deterministic`, owned by the pinned build). Only the row it
  writes differs. The row records whether the run tried for that sibling,
  held or not (`sibling_attempted`).

  `opts` are `ingest_toolchain/2`'s without `variant`, plus `:pins` (the set
  the job asked for) and `:pin_hash`, and optionally `:target`
  (`"pure_elixir"`) and `:builder_id`. The result must echo
  `requested_optional_deps: "pinned"`, or it is refused as an identity
  mismatch. A pass is stored as one only when the result's `pins` echo is
  this set, reproduced, and its `deps_lock` and `package_checksum` are
  exactly the set (`Compatibility.Pins.compare/2`): otherwise it is a
  `skipped` row with the reason and no files, so a build is never served
  under a closure it was not compiled against.

  An `:error` never replaces a pass or skipped row of the same identity, and
  a failed compile never replaces a served pass: the kept row records the
  attempt (`attempted_at`). Every write takes the identity's transaction
  lock first.

  A firmware target (`:target` a `nerves_system_*`, with `:system_version`,
  phase 2) is a full run's result.json of that one target
  (`Portal.Pins.FirmwareBuild`), and only `systems[target]` is read: no Run
  and no other target. The result must echo `"pinned"`, or it is refused as
  an identity mismatch. One whose own toolchain (`toolchain.elixir`,
  `toolchain.erlang`) is not the job's `:toolchain` is an `error` row with
  no files that names the toolchain it ran on. A target the run
  did not build (a closure the worker judged pure Elixir, or no such
  system) is a `skipped` row. A pass is stored as one only when, besides
  the checks above (its lock is the target's own, else the run's), the run
  was a `"targets"` run and the target was built on the job's
  `:system_version` exactly: otherwise a `skipped` row with no files. Its
  priv files' ELF facts (`Portal.Precompiled.ElfFacts`), toolchain, full OTP
  and library table are stored with it; its `compile_env` records no
  config reads, as any firmware target's.
  """
  @spec ingest_pinned(map(), map()) :: {:ok, PinnedBuild.t()} | {:error, term()}
  def ingest_pinned(result, %{target: "nerves_system_" <> _} = opts) when is_map(result) do
    keys = [:package, :version]

    with :ok <- check_identity(result, opts, keys),
         :ok <- check_pinned(result, opts, keys) do
      case firmware_toolchain(result) do
        toolchain when toolchain == opts.toolchain -> stage_pinned_target(result, opts)
        other -> write_toolchain_mismatch(result, opts, other)
      end
    end
  end

  def ingest_pinned(result, opts) when is_map(result) do
    keys = [:package, :version, :toolchain]

    with :ok <- check_identity(result, opts, keys),
         :ok <- check_pinned(result, opts, keys),
         :ok <- check_config_variant(result, opts, keys) do
      stage_toolchain_build(result, opts)
    end
  end

  defp check_pinned(%{"requested_optional_deps" => "pinned"}, _opts, _keys), do: :ok

  defp check_pinned(result, opts, keys) do
    {:error,
     {:identity_mismatch, opts |> Map.take(keys) |> Map.put(:variant, :pinned),
      result |> result_identity(keys) |> Map.put(:variant, result_variant(result))}}
  end

  # A firmware run records the toolchain it ran on, never a requested one.
  defp firmware_toolchain(result) do
    toolchain = if is_map(result["toolchain"]), do: result["toolchain"], else: %{}
    Portal.Toolchains.from_versions(toolchain["elixir"], toolchain["erlang"])
  end

  # A build on another toolchain than the job's is never stored as the
  # job's: the image moved off `Portal.Pins.firmware_toolchain/0`. It is an
  # `error` row of the job's identity with no files, carrying the toolchain
  # it ran on, so the wasted build shows in the catalog; as any `error`, it
  # never replaces a pass or skipped row.
  defp write_toolchain_mismatch(result, opts, reported) do
    toolchain = if is_map(result["toolchain"]), do: result["toolchain"], else: %{}

    Logger.error(
      "pinned build of #{opts.package} #{opts.version} ran on toolchain #{inspect(reported)}, " <>
        "not the job's #{opts.toolchain}: stored as an error"
    )

    build = %{
      "status" => "error",
      "reason" =>
        "pinned build on toolchain #{reported || "unknown"}, not the job's #{opts.toolchain}",
      "elixir" => fact_string(toolchain["elixir"]),
      "otp" => fact_string(toolchain["erlang"])
    }

    write_pinned_target(result, build, opts, [])
  end

  # The job's target as a build in the shape a pinned toolchain build has,
  # gated as it is, then staged whole or not at all, with its ELF facts read
  # from the staged blobs.
  defp stage_pinned_target(result, opts) do
    build =
      result
      |> target_build(opts)
      |> gate_build_root()
      |> gate_manifest()
      |> gate_release(result, opts)
      |> gate_pins(result, opts)
      |> keyed()

    # Checked first, and only for a target every gate passed: the check reads
    # the target's blobs from the run's files.
    sibling = pinned_sibling(build, result, opts)
    wanted = build |> Map.get("file_manifest") |> shas_from_manifest()
    staged = stage_shas(wanted, opts.files_dir)

    case wanted -- Enum.map(staged, & &1.sha256) do
      [] ->
        write_pinned_target(
          result,
          put_elf_facts(build),
          opts,
          staged,
          stage_sibling(sibling, opts, opts.target)
        )

      missing ->
        {:error, {:artifacts_unstaged, missing}}
    end
  end

  # The target's deterministic sibling (`Portal.Deterministic.Ingest.firmware_candidate/3`),
  # stored with the pinned row as a toolchain build's is.
  defp pinned_sibling(
         %{"status" => "pass", "file_manifest" => %{}},
         result,
         %{target: target} = opts
       ) do
    case result["systems"] do
      %{^target => %{} = sys} -> Portal.Deterministic.Ingest.firmware_candidate(target, sys, opts)
      _ -> :none
    end
  end

  defp pinned_sibling(_build, _result, _opts), do: :none

  defp write_pinned_target(result, build, opts, staged, sibling \\ nil) do
    Repo.transaction(
      fn ->
        :ok = lock_pinned_identity(opts)

        case write_pinned(result, build, target_verdict(build), opts, {staged, sibling}) do
          {:ok, pinned_build} -> pinned_build
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @transaction_timeout
    )
  end

  defp target_build(result, %{target: target}) do
    systems = if is_map(result["systems"]), do: result["systems"], else: %{}

    case systems[target] do
      %{} = sys -> target_build(result, sys)
      _ -> %{"status" => "skipped", "reason" => not_built(systems, target)}
    end
  end

  defp target_build(result, sys) do
    toolchain = if is_map(result["toolchain"]), do: result["toolchain"], else: %{}
    {toolchain_pkg, toolchain_version} = system_toolchain(sys["toolchain"])

    %{
      "status" => sys["status"],
      "reason" => target_reason(sys),
      "elixir" => toolchain["elixir"],
      "otp" => toolchain["erlang"],
      "deps_lock" => sys["deps_lock"] || result["deps_lock"],
      "package_checksum" => result["package_checksum"],
      "declared" => result["declared"],
      "compile_env" => sys["compile_env"],
      "compile_inputs" => sys["compile_inputs"],
      "file_manifest" => get_in(sys, ["beam_scan", "footprint", "file_manifest"]),
      "system_version" => sys["system_version"],
      "toolchain_pkg" => toolchain_pkg,
      "toolchain_version" => toolchain_version,
      "otp_full" => fact_string(sys["otp_full"]),
      "system_libs" => if(is_map(sys["system_libs"]), do: sys["system_libs"]),
      "build_root" => sys["build_root"]
    }
  end

  # A passing target the baked build path rule withheld
  # (`NccWorker.FirmwareBuildRoot`) already has no files: the worker deletes
  # the target's own `footprint.file_manifest`, but leaves its `status` at
  # "pass" -- only `build_root` records the refusal. Stored as a pass, the
  # row would show as served when nothing of it is, so it is stored as the
  # regular firmware path's own result reads it: skipped, with the worker's
  # reason. Absent on the toolchain path, whose `build_root` key the worker
  # never writes.
  defp gate_build_root(
         %{"status" => "pass", "build_root" => %{"status" => "skipped"} = build_root} = build
       ) do
    skip_variant(build, build_root["reason"] || "files withheld on the target (R2)")
  end

  defp gate_build_root(build), do: build

  defp not_built(%{"pure_elixir" => _}, _target),
    do: "pinned target not built: the worker judged the closure pure Elixir"

  defp not_built(_systems, target), do: "pinned target not built: the result has no #{target}"

  # A skipped target says why in its log tail (a refused set's is the
  # refusal); a failed or errored one names its error.
  defp target_reason(%{"status" => "pass"}), do: nil

  defp target_reason(%{"status" => "skipped"} = sys),
    do: bounded_reason(sys["log_tail"] || sys["error"])

  defp target_reason(sys),
    do: "firmware build #{sys["status"]}: " <> to_string(fact_string(sys["error"]) || "unknown")

  # A firmware target's verdict, as `create_system_result/7` maps its
  # status: anything but a pass, a skip or a failed build is no verdict.
  defp target_verdict(%{"status" => status, "reason" => reason})
       when status in ["pass", "skipped", "fail"],
       do: {String.to_existing_atom(status), reason}

  defp target_verdict(build), do: {:error, build["reason"]}

  # The release the target was built on must be the job's, exactly, and
  # only a targets run builds the one target asked for.
  defp gate_release(%{"status" => "pass"} = build, result, opts) do
    cond do
      result["scope"] != "targets" ->
        skip_variant(build, "pinned target not built alone: scope #{inspect(result["scope"])}")

      build["system_version"] != opts.system_version ->
        skip_variant(
          build,
          "pinned target built on #{opts.target} #{inspect(build["system_version"])}, " <>
            "not #{opts.system_version}"
        )

      true ->
        build
    end
  end

  defp gate_release(build, _result, _opts), do: build

  # Read from the blobs this ingest just staged; facts that cannot be read
  # are left out, which serves the build at its own release only anyway.
  defp put_elf_facts(%{"status" => "pass", "file_manifest" => %{} = manifest} = build) do
    case ElfFacts.compute_stored(
           ElfFacts.priv_entries(%{"footprint" => %{"file_manifest" => manifest}})
         ) do
      %{native: native, portable: portable, needs: needs} ->
        Map.merge(build, %{"native" => native, "portable" => portable, "elf_needs" => needs})

      {:error, reason} ->
        Logger.warning("ELF facts of a pinned firmware build not read: #{inspect(reason)}")
        build
    end
  end

  defp put_elf_facts(build), do: build

  # The config variant is the job's ("default" for a job from before config
  # variants); the result must say it was built in it. A worker that does not
  # know the request echoes nothing, which reads as "default".
  defp check_config_variant(result, opts, keys) do
    job = Map.get(opts, :config_variant, ConfigVariants.default())
    reported = result_config_variant(result)

    if reported == job,
      do: :ok,
      else:
        {:error,
         {:identity_mismatch, opts |> Map.take(keys) |> Map.put(:config_variant, job),
          result |> result_identity(keys) |> Map.put(:config_variant, reported)}}
  end

  defp result_config_variant(%{"toolchain_build" => %{"config_variant" => name}})
       when name != nil,
       do: name

  defp result_config_variant(_result), do: ConfigVariants.default()

  # The variant is part of a toolchain build's identity. The job's side
  # defaults to `:with`, for an ingest job enqueued before variants existed;
  # it is never taken from the result.
  defp check_variant(result, opts, keys) do
    variant = Map.get(opts, :variant, :with)

    case variant in ToolchainBuild.variants() do
      true ->
        case reported_variant(result, variant) do
          ^variant ->
            :ok

          reported ->
            job = opts |> Map.take(keys) |> Map.put(:variant, variant)

            {:error,
             {:identity_mismatch, job,
              result |> result_identity(keys) |> Map.put(:variant, reported)}}
        end

      false ->
        {:error, {:identity_missing, [:variant]}}
    end
  end

  # What a result says it was built as, for a job of `variant`. A result that
  # states nothing is held to a `:with` job, as results from before variants
  # were; a `:without` job takes only one that says it was built without
  # them, since an older worker drops the request and runs the optional pass
  # anyway. A result that reports an added optional dependency was built with
  # it, whatever it echoes.
  defp reported_variant(result, :with), do: result_variant(result) || :with

  defp reported_variant(result, :without) do
    if added_optional_deps?(result), do: :with, else: result_variant(result)
  end

  # A world job takes only a result that echoes its world: an older worker
  # refuses the request (exit 10) and writes no result at all.
  defp reported_variant(result, _world), do: result_variant(result)

  defp added_optional_deps?(%{"optional_deps" => %{"added" => added}})
       when added not in [nil, []],
       do: true

  defp added_optional_deps?(_result), do: false

  # The variant a toolchain result was built as. The worker echoes the
  # `optional_deps` request it was given (`requested_optional_deps`); a result
  # from a worker that does not echo it still says it never started the
  # optional pass (`optional_deps.reason` "not_requested"), which only a
  # build asked to exclude them reports. A world build echoes
  # `world:<name>`. Anything else states no variant.
  defp result_variant(%{"requested_optional_deps" => "include"}), do: :with
  defp result_variant(%{"requested_optional_deps" => "exclude"}), do: :without

  defp result_variant(%{"requested_optional_deps" => "world:" <> name} = echo) do
    case Compatibility.Worlds.variant(name) do
      {:ok, variant} -> variant
      :error -> echo["requested_optional_deps"]
    end
  end

  defp result_variant(%{"requested_optional_deps" => other}) when other != nil, do: other

  defp result_variant(%{"optional_deps" => %{"reason" => "not_requested"}}), do: :without
  defp result_variant(_result), do: nil

  defp stage_toolchain_build(result, opts) do
    build =
      result
      |> toolchain_build_map()
      |> relocated_files()
      |> gate_manifest()
      |> gate_relocation(opts)
      |> gate_config_variant(opts)
      |> gate_world_closure(opts)
      |> gate_pins(result, opts)

    case ToolchainPriv.verify(result, build, opts) do
      :ok -> relocation_checked(result, build, opts)
      {:refused, reason} -> stage_toolchain_build(result, refused(build, reason), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # S4 (`NccWorker.Portability.Relocate`): a pass whose own beams bake the
  # deps or build path, with the worker's record of every occurrence a
  # client rewrites at install (`Compatibility.Relocation`). The host checks
  # the record's shape against the build's own `ebin` and stores it
  # (`relocation`, `Portal.Catalog.RelocationMark`); the manifest lists the
  # build under `relocated` only (`Portal.Precompiled.Relocated`). A record
  # the host refuses, or one beside foreign priv files, publishes none of
  # the build's files. A pinned build has no column for one: it stays a
  # skip with no files. A dependent that passed because its dependency
  # proved relocatable carries no record and is a plain pass.
  @pinned_relocated "relocated build: a pinned build is not relocated"
  @relocated_shape "relocated_shape_ok"
  @relocation_refused "relocation refused on the host: "

  # The shape mark is taken off first, so no later gate reads it, whatever
  # the branch.
  defp gate_relocation(%{"status" => "pass", "relocation" => record} = build, opts) do
    {shaped, build} = Map.pop(build, @relocated_shape)

    cond do
      Map.has_key?(opts, :pins) ->
        build
        |> Map.delete("relocation")
        |> skip_variant(@pinned_relocated)

      problem = relocation_problem(record, build, shaped) ->
        build |> Map.delete("relocation") |> refused(problem, @relocation_refused)

      true ->
        build
    end
  end

  defp gate_relocation(build, _opts), do: Map.drop(build, ["relocation", @relocated_shape])

  # The client re-review's R7: every beam of a relocated build must have
  # been compiled from its package's dir under the record's deps path (its
  # `CInf` source, `Compatibility.Relocation.compiled_in_problem/3`), or
  # every client 0.9.0 fetches it and refuses it at install. The package's
  # dir is its app's, named by the build's one `.app` file. Read from the
  # run's files (or the store, on a retry); a blob in neither is the
  # retryable error staging gives.
  defp relocation_checked(result, build, opts) do
    case relocation_sources(build, opts) do
      :ok ->
        foreign_checked(result, build, opts)

      {:refused, why} ->
        build = build |> Map.delete("relocation") |> refused(why, @relocation_refused)
        stage_toolchain_build(result, build, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @max_relocated_ebin_bytes 256 * 1024 * 1024

  defp relocation_sources(%{"relocation" => %{"deps" => deps}} = build, opts) do
    entries =
      if relocated?(build), do: manifest_entries(build["file_manifest"], "ebin"), else: nil

    with [_ | _] <- entries,
         {:ok, app} <- relocated_app(entries),
         {:ok, beams} <- read_beams(entries, opts.files_dir) do
      case Compatibility.Relocation.compiled_in_problem(beams, deps, app) do
        nil -> :ok
        why -> {:refused, why}
      end
    else
      nil -> :ok
      [] -> {:refused, "no ebin"}
      other -> other
    end
  end

  defp relocation_sources(_build, _opts), do: :ok

  defp relocated_app(entries) do
    case for(%{"path" => "ebin/" <> name} <- entries, Path.extname(name) == ".app", do: name) do
      [name] -> {:ok, Path.basename(name, ".app")}
      _ -> {:refused, "not one .app file in its ebin"}
    end
  end

  # `%{file name => bytes}` of the ebin's beams, each read by its sha and
  # hashed again.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_beams(entries, files_dir) do
    entries
    |> Enum.filter(
      &(match?(%{"path" => "ebin/" <> _}, &1) and Path.extname(&1["path"]) == ".beam")
    )
    |> Enum.reduce_while({:ok, %{}, 0}, fn %{"path" => "ebin/" <> name} = entry,
                                           {:ok, acc, total} ->
      case read_beam(entry, files_dir) do
        {:ok, bytes} when total + byte_size(bytes) <= @max_relocated_ebin_bytes ->
          {:cont, {:ok, Map.put(acc, name, bytes), total + byte_size(bytes)}}

        {:ok, _bytes} ->
          {:halt, {:refused, "its ebin is too large to check"}}

        other ->
          {:halt, other}
      end
    end)
    |> case do
      {:ok, beams, _total} -> {:ok, beams}
      other -> other
    end
  end

  # The run's files dir, else the store (a retry after staging moved it);
  # the path is either joined with a sha checked to be 64 hex digits.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_beam(%{"sha256" => sha}, files_dir) when is_binary(sha) do
    with true <- sha =~ ~r/\A[0-9a-f]{64}\z/,
         {:ok, bytes} <- read_first([Path.join(files_dir, sha), ArtifactStore.blob_path(sha)]) do
      if Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha,
        do: {:ok, bytes},
        else: {:refused, "a beam that does not hash to its sha"}
    else
      false -> {:refused, "a beam with no valid sha"}
      :none -> {:error, {:artifacts_unstaged, [sha]}}
    end
  end

  defp read_beam(_entry, _files_dir), do: {:refused, "a beam with no valid sha"}

  defp read_first([]), do: :none

  # sobelow_skip ["Traversal.FileModule"]
  defp read_first([path | rest]) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> read_first(rest)
    end
  end

  defp relocation_problem(record, build, shaped) do
    cond do
      shaped != true ->
        "its files are not under relocated_file_manifest"

      (build["foreign_priv"] || []) != [] ->
        "beside foreign priv files"

      problem = Compatibility.Relocation.record_problem(record, ebin_paths(build)) ->
        problem

      problem = Compatibility.Relocation.pinned_problem(record) ->
        problem

      true ->
        nil
    end
  end

  # The umbrella review's B3: a relocated pass lists its files under
  # `relocated_file_manifest`, `file_manifest` nil, so a release before S4
  # finds nothing to serve. Here they are taken as the build's files for
  # every gate and the staging, and `upsert_toolchain_build/5` stores them
  # back under `relocated_file_manifest`. A relocated pass in any other
  # shape is marked for `gate_relocation/2` to refuse; any other build's
  # `relocated_file_manifest` is dropped.
  defp relocated_files(%{"status" => "pass", "relocation" => %{}} = build) do
    case {build["file_manifest"], build["relocated_file_manifest"]} do
      {nil, %{} = manifest} ->
        build
        |> Map.delete("relocated_file_manifest")
        |> Map.merge(%{"file_manifest" => manifest, @relocated_shape => true})

      _ ->
        build |> Map.delete("relocated_file_manifest") |> Map.put(@relocated_shape, false)
    end
  end

  defp relocated_files(build), do: Map.delete(build, "relocated_file_manifest")

  defp ebin_paths(%{"file_manifest" => %{"ebin" => entries}}) when is_list(entries),
    do: for(%{"path" => path} when is_binary(path) <- entries, do: path)

  defp ebin_paths(_build), do: []

  defp relocated?(%{"status" => "pass", "relocation" => %{}}), do: true
  defp relocated?(_build), do: false

  # Foreign priv spec 4.2, once the build's own priv held: the archives its
  # compile wrote into kino's priv, proved again on the host
  # (`ToolchainForeignPriv`). A refusal publishes none of the build's files.
  defp foreign_checked(result, build, opts) do
    case ToolchainForeignPriv.verify(result, build, opts) do
      :ok ->
        stage_toolchain_build(result, keyed(build), opts)

      {:refused, why} ->
        stage_toolchain_build(
          result,
          refused(build, why, "foreign priv refused on the host: "),
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A client installs `ebin` entries as code and `priv` entries as data, and
  # an entry is served only under the key its own path names
  # (`Portal.Catalog.precompiled_manifest_v2/1`). No build writes an entry
  # under the other key, so a pass build that does is stored as a `fail`
  # with no files rather than as a pass the manifest would never serve.
  defp keyed(%{"file_manifest" => %{} = manifest} = build) do
    case misplaced_entry(manifest) do
      nil ->
        build

      {key, path} ->
        shown =
          "#{inspect(path, printable_limit: 200, limit: 3)} under #{inspect(key, printable_limit: 50)}"

        Logger.warning("security: toolchain build lists #{shown}; publishing nothing")

        Map.merge(build, %{
          "status" => "fail",
          "reason" => "manifest lists #{shown}",
          "file_manifest" => nil
        })
    end
  end

  defp keyed(build), do: build

  defp misplaced_entry(manifest) do
    Enum.find_value(@manifest_keys, fn key ->
      manifest
      |> manifest_entries(key)
      |> Enum.find_value(&misplaced(&1, key))
    end)
  end

  # The path as listed, a container-supplied value that may not even be a
  # string: `keyed/1` bounds it when it shows it.
  defp misplaced(%{"path" => path}, key) when is_binary(path) do
    if String.starts_with?(path, key <> "/"), do: nil, else: {key, path}
  end

  defp misplaced(entry, key), do: {key, is_map(entry) && entry["path"]}

  # A build whose priv files the host refused publishes none of its files,
  # beams included: its beams read data that is not published with them. It
  # is stored as a `fail`, a verdict the sweep leaves alone rather than one
  # it re-queues at once.
  defp refused(build, reason, prefix \\ "priv refused on the host: ") do
    Map.merge(build, %{
      "status" => "fail",
      "reason" => prefix <> reason,
      "file_manifest" => nil,
      "foreign_priv" => nil,
      "foreign_priv_rule" => nil
    })
  end

  defp stage_toolchain_build(result, build, opts) do
    # Checked first: the check reads the build's blobs from the run's files.
    # A relocated build has no sibling: the worker never relocates one.
    sibling =
      if relocated?(build),
        do: :none,
        else: Portal.Deterministic.Ingest.candidate(result, build, opts)

    wanted = shas_from_manifest(Map.get(build, "file_manifest")) ++ foreign_shas(build)
    staged = stage_shas(wanted, opts.files_dir)

    case wanted -- Enum.map(staged, & &1.sha256) do
      [] ->
        write_toolchain_build(result, build, opts, staged, stage_sibling(sibling, opts))

      # A pass build publishes every file of its manifest or none: storing it
      # with a file missing would replace a complete published build with a
      # broken one. Failing before the transaction leaves the previous row and
      # its memberships alone, and the worker keeps the scratch dir until the
      # last attempt, so a retry can stage the file again.
      missing ->
        {:error, {:artifacts_unstaged, missing}}
    end
  end

  # A pass build's foreign priv archives (`ToolchainForeignPriv` proved
  # them): staged with its own files, all or nothing, and owned by its row.
  defp foreign_shas(%{"status" => "pass", "foreign_priv" => [_ | _] = entries}),
    do: for(%{"sha256" => sha} <- entries, do: sha)

  defp foreign_shas(_build), do: []

  # Each firmware target's deterministic sibling, checked before its blobs
  # are staged (`Portal.Deterministic.Ingest.firmware_candidate/3`).
  defp firmware_siblings(systems, opts) when is_map(systems) do
    for {system_pkg, %{} = sys} <- systems,
        into: %{},
        do: {system_pkg, Portal.Deterministic.Ingest.firmware_candidate(system_pkg, sys, opts)}
  end

  defp firmware_siblings(_systems, _opts), do: %{}

  # The deterministic sibling (`Portal.Deterministic.Ingest`), checked and
  # its blobs staged before the transaction, as the build's are: `nil` when
  # the result carries none or it did not hold. Every blob or none: a sibling
  # with a file missing is left out, and the build is stored without it.
  defp stage_sibling(candidate, opts, target \\ nil) do
    of =
      "deterministic sibling of #{opts.package} #{opts.version}#{if target, do: " on #{target}"}"

    case candidate do
      {:ok, sibling} ->
        staged = stage_shas(Enum.uniq(sibling["shas"]), opts.files_dir)

        case Enum.uniq(sibling["shas"]) -- Enum.map(staged, & &1.sha256) do
          [] ->
            Map.put(sibling, "staged", staged)

          missing ->
            Logger.warning("#{of} left out: #{length(missing)} blobs not staged")

            nil
        end

      {:skip, reason} ->
        Logger.warning("#{of} left out: " <> reason)

        nil

      :none ->
        nil
    end
  end

  defp write_toolchain_build(result, build, %{pins: _} = opts, staged, sibling) do
    Repo.transaction(
      fn ->
        :ok = lock_pinned_identity(opts)

        case write_pinned(result, build, toolchain_verdict(build), opts, {staged, sibling}) do
          {:ok, pinned_build} -> pinned_build
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @transaction_timeout
    )
  end

  defp write_toolchain_build(result, build, opts, staged, sibling) do
    Repo.transaction(
      fn ->
        :ok = lock_toolchain_identity(opts)

        case do_ingest_toolchain(result, build, opts, staged, sibling) do
          {:ok, toolchain_build} -> toolchain_build
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @transaction_timeout
    )
  end

  # Only a pass build has files to publish. A manifest on any other status is
  # dropped, so it is neither staged nor stored nor given memberships.
  defp gate_manifest(%{"status" => "pass"} = build), do: build
  defp gate_manifest(build), do: Map.put(build, "file_manifest", nil)

  # A named variant is published only when it shows its overlay was in
  # effect: marked (its config reads recorded, rule 1 next to a kept
  # `compile_env`) and every recorded overlay key at the overlay's value
  # (`ConfigVariants.overlay_recorded/2`). Anything else is a deterministic
  # skip with no files.
  defp gate_config_variant(%{"status" => "pass"} = build, %{config_variant: name})
       when name != @default_config_variant do
    resolved = compile_env(build["compile_env"])

    with {:mark, 1} <- {:mark, compile_env_rule(build["compile_env_rule"], resolved)},
         :ok <- ConfigVariants.overlay_recorded(name, resolved) do
      build
    else
      {:mark, _} -> skip_variant(build, "config variant records no config reads")
      {:error, reason} -> skip_variant(build, reason)
    end
  end

  defp gate_config_variant(build, _opts), do: build

  # A world build whose closure came out equal to a live build of another
  # variant of the same version (the with or without one first) is that
  # build again: a client that reads both lists would see one build twice.
  # It is stored as a deterministic skip with no files and its own lock, so
  # the backlog does not want it again while the row stands.
  defp gate_world_closure(%{"status" => "pass"} = build, opts) do
    with variant when variant not in [nil, :with, :without] <- Map.get(opts, :variant),
         %{} = deps <- deps_lock(build["deps_lock"]),
         [[other]] <- same_closure(opts, variant, deps) do
      skip_variant(build, "same closure as the #{other} build")
    else
      _ -> build
    end
  end

  defp gate_world_closure(build, _opts), do: build

  @same_closure_sql """
  SELECT t.variant
  FROM catalog_toolchain_builds t
  JOIN catalog_packages p ON p.id = t.package_id
  WHERE p.name = $1 AND t.version = $2 AND t.toolchain = $3 AND t.builder_version = $4
    AND t.config_variant = $5 AND t.variant <> $6 AND t.variant IN #{ToolchainBuild.variants_sql()}
    AND t.revoked_at IS NULL AND t.status IN ('pass', 'skipped')
    AND t.deps_lock = $7::jsonb
  ORDER BY CASE t.variant WHEN 'with' THEN 0 WHEN 'without' THEN 1 ELSE 2 END, t.variant
  LIMIT 1
  """

  defp same_closure(opts, variant, deps) do
    Repo.query!(@same_closure_sql, [
      opts.package,
      opts.version,
      opts.toolchain,
      opts.builder_version,
      Map.get(opts, :config_variant, ConfigVariants.default()),
      Atom.to_string(variant),
      deps
    ]).rows
  end

  # A pinned build passes as one only when the worker says it reproduced
  # this set and the lock it compiled against is exactly the set: the
  # published `deps` is what Mix resolved, and it must be what was asked for.
  defp gate_pins(%{"status" => "pass"} = build, result, %{pins: pins, pin_hash: hash}) do
    echo = if is_map(result["pins"]), do: result["pins"], else: %{}

    cond do
      echo["status"] != "reproduced" or echo["hash"] != hash ->
        skip_variant(build, "pins not reproduced: the result does not echo the set")

      build["package_checksum"] != pins["package_checksum"] ->
        skip_variant(build, "pins not reproduced on the host: pins_checksum_mismatch")

      true ->
        case Compatibility.Pins.compare(pins["deps"], deps_lock(build["deps_lock"])) do
          :ok ->
            build

          {:mismatch, reason, diff} ->
            skip_variant(
              build,
              "pins not reproduced on the host: " <> Compatibility.Pins.describe(reason, diff)
            )
        end
    end
  end

  defp gate_pins(build, _result, _opts), do: build

  defp skip_variant(build, reason),
    do: Map.merge(build, %{"status" => "skipped", "reason" => reason, "file_manifest" => nil})

  defp toolchain_build_map(%{"toolchain_build" => %{} = build}), do: build
  defp toolchain_build_map(_result), do: raise("result.json missing toolchain_build")

  @doc """
  Takes the transaction-scoped lock on the toolchain build identity in
  `opts` (`:package`, `:version`, `:toolchain`, `:builder_version`,
  `:variant`, `:with` when absent, and `:config_variant`, `"default"` when
  absent), which every toolchain ingest takes before it reads the identity's
  row. Call it inside a `Repo` transaction; the lock is released when that
  transaction ends.
  """
  @spec lock_toolchain_identity(map()) :: :ok
  def lock_toolchain_identity(opts) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [toolchain_lock_key(opts)])
    :ok
  end

  @doc false
  def toolchain_lock_key(opts) do
    base = [
      "toolchain_build",
      opts.package,
      opts.version,
      opts.toolchain,
      opts.builder_version,
      Map.get(opts, :variant, :with)
    ]

    # A default's key is the one the release before config variants takes,
    # so both releases serialise their writes of a default row on one lock.
    case Map.get(opts, :config_variant, ConfigVariants.default()) do
      @default_config_variant -> Enum.join(base, "@")
      name -> Enum.join(base ++ [name], "@")
    end
  end

  defp do_ingest_toolchain(result, build, opts, staged, sibling) do
    package_info = result |> Map.get("package", %{}) |> with_job_version(opts)
    package_name = package_name(package_info, opts)
    verdict = toolchain_verdict(build)
    transient? = transient_verdict?(verdict, build)

    with {:ok, package} <- ensure_package(package_name, package_info) do
      case kept_toolchain_build(verdict, build, package.id, opts) do
        %ToolchainBuild{} = kept ->
          mark_retried(kept, transient?)

        nil ->
          counted = counted(verdict, transient?, package.id, opts)
          write_toolchain_row(result, build, counted, opts, package.id, {staged, sibling})
      end
    end
  end

  # The row's deterministic sibling is replaced with the row
  # (`Portal.Deterministic.replace/2`): a sibling belongs to the run that
  # wrote the row, so a rebuild without one leaves the row without one.
  defp write_toolchain_row(result, build, counted, opts, package_id, {staged, sibling}) do
    replaced = identity_row(package_id, opts)

    with {:ok, toolchain_build} <-
           upsert_toolchain_build(result, build, counted, opts, package_id),
         {:ok, toolchain_build} <- maybe_unrevoke(toolchain_build),
         {:ok, toolchain_build} <- record_earlier_builds(toolchain_build, replaced) do
      :ok = upsert_artifacts(staged ++ ((sibling && sibling["staged"]) || []))

      :ok =
        replace_toolchain_memberships(
          toolchain_build.id,
          staged,
          EarlierBuilds.shas(toolchain_build.earlier_builds)
        )

      with :ok <- Portal.Deterministic.replace(toolchain_build, sibling),
           do: {:ok, toolchain_build}
    end
  end

  # The row of the identity before this ingest writes it, whatever its
  # status, read under the identity's lock: the build it serves becomes an
  # earlier build when the new one has another lock.
  defp identity_row(package_id, opts) do
    variant = Map.get(opts, :variant, :with)
    config_variant = Map.get(opts, :config_variant, ConfigVariants.default())

    ToolchainBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^opts.version and
        toolchain == ^opts.toolchain and builder_version == ^opts.builder_version and
        variant == ^variant and config_variant == ^config_variant
    )
    |> Ash.read_one!(domain: @domain)
  end

  # A passing rebuild with another dependency lock keeps the build it
  # replaced (`ToolchainBuild.EarlierBuilds.push/3`): a project still locked
  # at the older dependency keeps its hit. A rebuild that does not pass is a
  # verdict on the package's build (a refusal or a skip), not on one lock, so
  # it drops them with the row's own. Written only when the list changes, so
  # a rebuild with the same lock writes nothing more than before.
  defp record_earlier_builds(toolchain_build, replaced) do
    current = List.wrap(toolchain_build.earlier_builds)

    earlier =
      EarlierBuilds.push(
        replaced,
        if(replaced, do: replaced.earlier_builds, else: current),
        toolchain_build
      )

    if earlier == current do
      {:ok, toolchain_build}
    else
      toolchain_build
      |> Ash.Changeset.for_update(:record_earlier_builds, %{earlier_builds: earlier})
      |> Ash.update(domain: @domain)
    end
  end

  # A row revoked for its withheld closure (`Portal.Catalog.mark_withheld_revoked/2`)
  # whose rebuild records its compile-time config reads
  # (`Withheld.records_config_reads?/1`: rule 1 next to a kept `compile_env`,
  # written by this run) and passed is no longer withheld, so the rebuild
  # un-revokes it, in the transaction that wrote the row. A rebuild without
  # them (an older worker image), a failed or skipped rebuild, or a row
  # revoked for any other reason stays revoked and keeps its mark.
  defp maybe_unrevoke(%ToolchainBuild{status: :pass} = tb) do
    if tb.revoked_at != nil and tb.revoked_reason == ToolchainBuild.withheld_revocation() and
         Withheld.records_config_reads?(tb),
       do: unrevoke(tb),
       else: {:ok, tb}
  end

  defp maybe_unrevoke(tb), do: {:ok, tb}

  # The action's own filter re-checks the reason; a row that no longer
  # matches it (a stale record) keeps its revocation rather than failing the
  # ingest.
  defp unrevoke(tb) do
    case tb |> Ash.Changeset.for_update(:unrevoke_rebuilt, %{}) |> Ash.update(domain: @domain) do
      {:ok, unrevoked} ->
        {:ok, unrevoked}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.all?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
          do: {:ok, tb},
          else: {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  # An `:error` gives no verdict, so a pass or skipped row of the same
  # identity stays, files and memberships alike.
  defp kept_toolchain_build({:error, _reason}, _build, package_id, opts),
    do: kept_row(package_id, opts, [:pass, :skipped])

  # A failed compile keeps a served `pass` row: the backlog only rebuilds an
  # unchanged version on the same image to refresh what it records, so a
  # compile that now fails is the environment's doing, not news about the
  # package. Every other `fail` is a refusal (the host's priv check, a
  # misplaced manifest entry, processes that survived the build), and a
  # refusal or a skip is a verdict on what the build publishes, which
  # replaces it. A revoked row serves nothing to keep, so a failed rebuild
  # of one is stored, revocation and its reason included.
  defp kept_toolchain_build({:fail, "compile failed: " <> _}, %{"status" => "error"}, id, opts),
    do: kept_row(id, opts, [:pass], served_only: true)

  defp kept_toolchain_build(_verdict, _build, _package_id, _opts), do: nil

  defp kept_row(package_id, opts, statuses, kept_opts \\ []) do
    variant = Map.get(opts, :variant, :with)
    config_variant = Map.get(opts, :config_variant, ConfigVariants.default())

    ToolchainBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^opts.version and
        toolchain == ^opts.toolchain and builder_version == ^opts.builder_version and
        variant == ^variant and config_variant == ^config_variant and status in ^statuses
    )
    |> served_only(Keyword.get(kept_opts, :served_only, false))
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: @domain)
  end

  defp served_only(query, true), do: Ash.Query.filter(query, is_nil(revoked_at))
  defp served_only(query, false), do: query

  # A transient "could not be judged" says nothing about the package, so it
  # is retried; `ToolchainBuild.transient_cap/0` of them in a row at one
  # builder version (a package that always times out) is a skip the backlog
  # leaves alone. A verdict resets the count; another `:error` is no verdict
  # and keeps it.
  defp counted({:error, reason}, true, package_id, opts) do
    attempts = previous_transient_attempts(package_id, opts) + 1

    if attempts >= ToolchainBuild.transient_cap(),
      do: {{:skipped, "#{reason} (transient #{attempts} times)"}, attempts},
      else: {{:error, reason}, attempts}
  end

  defp counted({:error, _reason} = verdict, false, package_id, opts),
    do: {verdict, previous_transient_attempts(package_id, opts)}

  defp counted(verdict, false, _package_id, _opts), do: {verdict, 0}

  @doc """
  The `transient_attempts` of the `:error` row for the toolchain build
  identity in `opts` (`:version`, `:toolchain`, `:builder_version`,
  `:variant`, `:with` when absent, and `:config_variant`, `"default"` when
  absent) of the package `package_id`; 0 when there is none. Only an `:error` row carries a count on: a pass or skipped row is
  kept, and a `fail` is a verdict. Read it under `lock_toolchain_identity/1`.
  """
  @spec previous_transient_attempts(String.t(), map()) :: non_neg_integer()
  def previous_transient_attempts(package_id, opts) do
    variant = Map.get(opts, :variant, :with)
    config_variant = Map.get(opts, :config_variant, ConfigVariants.default())

    ToolchainBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^opts.version and
        toolchain == ^opts.toolchain and builder_version == ^opts.builder_version and
        variant == ^variant and config_variant == ^config_variant and status == :error
    )
    |> Ash.Query.select([:transient_attempts])
    |> Ash.read_one!(domain: @domain)
    |> case do
      %ToolchainBuild{transient_attempts: n} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp transient_verdict?({:error, reason}, build),
    do: reason == Compatibility.Portability.could_not_judge() and transient_trace?(build)

  defp transient_verdict?(_verdict, _build), do: false

  # `:retried_transient` sets the count it is given; `:upsert` would reset it.
  defp mark_retried(row, true) do
    row
    |> Ash.Changeset.for_update(:retried_transient, %{
      transient_attempts: row.transient_attempts + 1
    })
    |> Ash.update(domain: @domain)
  end

  defp mark_retried(row, false) do
    row |> Ash.Changeset.for_update(:retried, %{}) |> Ash.update(domain: @domain)
  end

  # Creates the package when it is new and otherwise leaves every field alone.
  # The conflict update names only `name`, which is the conflict key and so
  # unchanged; `:upsert`'s own field list would overwrite `last_run_at` and
  # `latest_version` with what a toolchain build has no say over.
  @doc """
  The id of the package named `name`, its row created with the name alone
  when the catalog has none, as a toolchain or pinned ingest creates one: no
  latest version, no description. `Portal.Workers.PinnedBuild.write_row/5`
  records a build no ingest will under it.
  """
  @spec ensure_package_id(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def ensure_package_id(name) when is_binary(name) do
    with {:ok, package} <- ensure_package(name, %{}), do: {:ok, package.id}
  end

  defp ensure_package(name, info) do
    Package
    |> Ash.Changeset.for_create(:upsert, %{
      name: name,
      description: info["description"],
      latest_version: info["version"],
      native_components: info["native_components"]
    })
    |> Ash.create(domain: @domain, upsert_fields: [:name])
  end

  defp upsert_toolchain_build(result, build, {{status, reason}, attempts}, opts, package_id) do
    {inputs, compiled_env} = inputs_and_env(build, {opts.package, opts.version})

    ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package_id,
      version: opts.version,
      toolchain: opts.toolchain,
      builder_version: opts.builder_version,
      variant: Map.get(opts, :variant, :with),
      config_variant: Map.get(opts, :config_variant, ConfigVariants.default()),
      status: status,
      reason: judged_reason(reason, build),
      elixir: build["elixir"],
      otp: build["otp"],
      image_digest: opts.image_digest,
      run_id: opts.run_id,
      deps_lock: deps_lock(build["deps_lock"]),
      package_checksum: package_checksum(build["package_checksum"]),
      declared: declared(build["declared"]),
      compile_env: compiled_env,
      compile_inputs: inputs,
      file_manifest:
        if(relocation(status, build), do: nil, else: file_manifest(build["file_manifest"])),
      relocated_file_manifest:
        if(relocation(status, build), do: file_manifest(build["file_manifest"])),
      optional_deps: optional_deps(result["optional_deps"]),
      portability_rule: portability_rule(build["portability_rule"]),
      rule1_reason: bounded_reason(build["rule1_reason"]),
      judge_revision: judge_revision(build["judge_revision"]),
      manager: manager(build["manager"]),
      compile_observations: compile_observations(build["compile_observations"]),
      compile_env_rule: compile_env_rule(Map.get(build, "compile_env_rule"), compiled_env),
      foreign_priv: foreign_priv(status, build),
      foreign_priv_rule: foreign_priv_rule(status, build),
      relocation: relocation(status, build),
      transient_attempts: attempts,
      finished_at: parse_datetime(result["finished_at"]),
      # Named, or the upsert leaves the kept row's attempt in place: the
      # backlog reopens a row by its last attempt, and a stale one makes a
      # build that just landed look due.
      attempted_at: nil
    })
    |> Ash.create(domain: @domain)
  end

  defp optional_deps(%{} = optional_deps), do: optional_deps
  defp optional_deps(_), do: nil

  # A pass build's foreign priv list and rule, as the host checked them
  # (`ToolchainForeignPriv`); none on any other status, a gate's skip
  # included, so no unchecked list is ever stored.
  defp foreign_priv(:pass, %{"foreign_priv" => entries}) when is_list(entries), do: entries
  defp foreign_priv(_status, _build), do: nil

  defp foreign_priv_rule(:pass, %{"foreign_priv" => [_ | _], "foreign_priv_rule" => rule})
       when is_binary(rule),
       do: rule

  defp foreign_priv_rule(_status, _build), do: nil

  # A pass build's relocation record, as the host checked it
  # (`gate_relocation/2`); none on any other status.
  defp relocation(:pass, %{"relocation" => %{} = record}), do: record
  defp relocation(_status, _build), do: nil

  @max_observation_bytes 256 * 1024

  defp portability_rule(rule) when is_integer(rule) and rule in 1..9, do: rule
  defp portability_rule(_rule), do: nil

  # The worker's judge revision; anything but a small positive integer is
  # none, which the backlog reads as "before revisions".
  defp judge_revision(revision) when is_integer(revision) and revision in 1..1_000_000,
    do: revision

  defp judge_revision(_revision), do: nil

  defp manager(manager) when manager in ["mix", "rebar3", "make"], do: manager
  defp manager(_manager), do: nil

  @doc """
  The reason a build's row stores: a could-not-judge names its cause
  (`Compatibility.Portability.with_cause/2`), one of the problems of the
  build's own trace (`compile_observations.problems`, which the row keeps
  in full); a failed host compile names its first compiler error
  (`Compatibility.Portability.with_compile_error/2`, from the worker's
  `compile_observations.compile_error`), unless a signal ended it; any
  other reason as the worker gave it. The worker's reason is the bare one,
  so this runs after the transient check and count, and the kept-row check,
  which read it.
  """
  @spec judged_reason(term(), map()) :: term()
  def judged_reason(reason, build) do
    reason
    |> Compatibility.Portability.with_cause(trace_problems(build))
    |> Compatibility.Portability.with_compile_error(compile_error(build))
  end

  defp trace_problems(%{"compile_observations" => %{"problems" => problems}}), do: problems
  defp trace_problems(_build), do: nil

  defp compile_error(%{"compile_observations" => %{"compile_error" => error}}), do: error
  defp compile_error(_build), do: nil

  defp bounded_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)
  defp bounded_reason(_reason), do: nil

  # The trace's own account, kept for measurement and audit; bounded so one
  # build cannot bloat the row.
  defp compile_observations(%{} = observations) do
    if byte_size(Jason.encode!(observations)) <= @max_observation_bytes,
      do: observations,
      else: %{"truncated" => true}
  end

  defp compile_observations(_observations), do: nil

  # The worker's `"error"` is a failed host compile, which is deterministic for
  # this package, version and toolchain: it is stored as a `:fail` verdict,
  # which the backlog does not build again at this `builder_version` (only a
  # compile a signal killed, see `Portal.Catalog.toolchain_backlog/3`). `:error` rows mean the build gave
  # no usable result: `Portal.Workers.ToolchainBuild` writes those, and so
  # does a portal build whose process sweep could not run at all (below).
  # Processes the worker could not stop after the build
  # (`NccWorker.ProcessSweep`) are a `:fail`, under the worker's own label.
  defp toolchain_verdict("error", "processes survived the sweep" <> _ = reason),
    do: {:fail, "worker: " <> reason}

  # A sweep that could not run at all is the image's or the runtime's doing,
  # not the package's: an `:error`, which the backlog retries after a day,
  # rather than a verdict that would hold every package back for a week.
  defp toolchain_verdict("error", "process sweep could not run" <> _ = reason),
    do: {:error, "worker: " <> reason}

  defp toolchain_verdict("error", reason),
    do: {:fail, "compile failed: " <> (reason || "unknown")}

  defp toolchain_verdict(status, reason), do: {Compatibility.Types.parse_status(status), reason}

  # A could-not-judge the worker marks transient is no verdict on the
  # package: an `:error`, retried after a day (see `ingest_toolchain/2`).
  defp toolchain_verdict(%{"status" => "skipped", "reason" => reason} = build) do
    if reason == Compatibility.Portability.could_not_judge() and transient_trace?(build),
      do: {:error, reason},
      else: toolchain_verdict("skipped", reason)
  end

  defp toolchain_verdict(build), do: toolchain_verdict(build["status"], build["reason"])

  defp transient_trace?(%{"compile_observations" => %{"trace_stats" => %{"transient" => true}}}),
    do: true

  defp transient_trace?(_build), do: false

  defp file_manifest(%{} = manifest), do: manifest
  defp file_manifest(_), do: nil

  # The memberships of a toolchain build are exactly the shas this ingest
  # staged, which `ingest_toolchain/2` has checked is the whole manifest.
  # Shas the row held from an earlier build of the same identity and this one
  # no longer produces are removed first. A retry stages the same shas again
  # (`ArtifactStore.put/2` verifies an already moved blob), so it removes
  # nothing.
  # The row's memberships become its new build's files and those of the
  # earlier builds it keeps (`ToolchainBuild.EarlierBuilds`), which were the
  # row's memberships already; only the new build's are inserted.
  defp replace_toolchain_memberships(toolchain_build_id, staged, kept) do
    shas = staged |> Enum.map(& &1.sha256) |> Enum.uniq() |> Enum.sort()

    Repo.query!(
      """
      DELETE FROM catalog_artifact_memberships
      WHERE toolchain_build_id = $1 AND NOT (sha256 = ANY($2::text[]))
      """,
      [dump(toolchain_build_id), Enum.uniq(shas ++ kept)]
    )

    shas
    |> Enum.map(&%{sha256: &1, toolchain_build_id: toolchain_build_id})
    |> insert_memberships(:upsert_toolchain, :unique_toolchain_build_sha256)
  end

  @doc """
  Takes the transaction-scoped lock on the pinned build identity in `opts`
  (`:package`, `:version`, `:pin_hash`, `:target`, `:toolchain`,
  `:builder_version`, `:config_variant`), which every write of a pinned
  build row takes first.
  """
  @spec lock_pinned_identity(map()) :: :ok
  def lock_pinned_identity(opts) do
    key =
      Enum.join(
        [
          "pinned_build",
          opts.package,
          opts.version,
          opts.pin_hash,
          Map.get(opts, :target, "pure_elixir"),
          Map.get(opts, :system_version, ""),
          opts.toolchain,
          opts.builder_version,
          Map.get(opts, :config_variant, ConfigVariants.default())
        ],
        "@"
      )

    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [key])
    :ok
  end

  # A pinned build is no run, so it never writes the package row's
  # `latest_version` or `description` (`Portal.Catalog.LatestRun`): a
  # package the catalog does not hold yet is created with its name alone,
  # as a host-native ingest creates one.
  defp write_pinned(result, build, verdict, opts, staged) do
    package_info = result |> Map.get("package", %{}) |> with_job_version(opts)

    with {:ok, package} <- ensure_package(package_name(package_info, opts), %{}) do
      case backfill_kept(verdict, staged, package.id, opts) do
        {:ok, _row} = kept -> kept
        {:error, _reason} = error -> error
        nil -> write_pinned_verdict(result, build, verdict, opts, package.id, staged)
      end
    end
  end

  defp write_pinned_verdict(result, build, verdict, opts, package_id, staged) do
    case kept_pinned(verdict, build, package_id, opts) do
      %PinnedBuild{} = kept ->
        kept |> Ash.Changeset.for_update(:retried, %{}) |> Ash.update(domain: @domain)

      nil ->
        upsert_pinned(result, build, verdict, opts, package_id, staged)
    end
  end

  # A sibling backfill's rebuild replaces the key's row only with a pass
  # whose sibling held and was staged; see `backfill_attempted/2`.
  defp backfill_kept({:pass, _reason}, {_staged, %{}}, _package_id, _opts), do: nil

  defp backfill_kept(_verdict, _staged, package_id, opts) do
    if backfill?(opts), do: backfill_attempted(package_id, opts)
  end

  defp backfill?(opts), do: Map.get(opts, :sibling_backfill) == true

  @doc false
  # A sibling backfill's rebuild (`Portal.Pins.from_lock/2`'s
  # `deterministic: true`, the job's `sibling_backfill`) that brought
  # anything but a pass with its sibling: a fail, a skip, an error, a
  # timeout, another toolchain, or a pass whose sibling was refused or
  # absent. The key's row stays as it is, its status, files, memberships
  # and sibling, and only records the attempt (`sibling_attempted`):
  # `{:ok, row}`, or `{:error, reason}` when that write failed. `nil` when
  # the key has no row: nothing pinned is served to keep, and the rebuild's
  # verdict is written as any pinned build's, with the attempt. Under the
  # identity's lock, which the caller holds.
  @spec backfill_attempted(Ecto.UUID.t(), map()) ::
          {:ok, PinnedBuild.t()} | {:error, term()} | nil
  def backfill_attempted(package_id, opts) do
    case pinned_row(package_id, opts, [:pass, :skipped, :fail, :error], false) do
      nil ->
        nil

      row ->
        row |> Ash.Changeset.for_update(:sibling_attempted, %{}) |> Ash.update(domain: @domain)
    end
  end

  # As `kept_toolchain_build/4`: an `:error` keeps a pass or skipped row, a
  # failed compile keeps a served pass.
  defp kept_pinned({:error, _reason}, _build, package_id, opts),
    do: pinned_row(package_id, opts, [:pass, :skipped], false)

  defp kept_pinned({:fail, "compile failed: " <> _}, %{"status" => "error"}, package_id, opts),
    do: pinned_row(package_id, opts, [:pass], true)

  defp kept_pinned(_verdict, _build, _package_id, _opts), do: nil

  @doc false
  # The row of the pinned identity in `opts` with one of `statuses`; `served`
  # only one that is neither revoked nor withdrawn.
  def pinned_row(package_id, opts, statuses, served) do
    key = [
      package_id: package_id,
      version: opts.version,
      pin_hash: opts.pin_hash,
      target: Map.get(opts, :target, "pure_elixir"),
      system_version: Map.get(opts, :system_version, ""),
      toolchain: opts.toolchain,
      builder_version: opts.builder_version,
      config_variant: Map.get(opts, :config_variant, ConfigVariants.default())
    ]

    PinnedBuild
    |> Ash.Query.filter(^key)
    |> Ash.Query.filter(status in ^statuses)
    |> served_pinned(served)
    |> Ash.read_one!(domain: @domain)
  end

  defp served_pinned(query, true),
    do: Ash.Query.filter(query, is_nil(revoked_at) and is_nil(unpublished_at))

  defp served_pinned(query, false), do: query

  defp upsert_pinned(result, build, {status, reason}, opts, package_id, {staged, sibling}) do
    {inputs, compiled_env} = inputs_and_env(build, {opts.package, opts.version})

    attrs = %{
      package_id: package_id,
      version: opts.version,
      pin_hash: opts.pin_hash,
      target: Map.get(opts, :target, "pure_elixir"),
      system_version: Map.get(opts, :system_version, ""),
      toolchain: opts.toolchain,
      builder_version: opts.builder_version,
      config_variant: Map.get(opts, :config_variant, ConfigVariants.default()),
      pins: opts.pins,
      status: status,
      reason: judged_reason(reason, build),
      elixir: build["elixir"],
      otp: build["otp"],
      image_digest: opts.image_digest,
      run_id: opts.run_id,
      builder_id: Map.get(opts, :builder_id),
      deps_lock: deps_lock(build["deps_lock"]),
      package_checksum: package_checksum(build["package_checksum"]),
      declared: declared(build["declared"]),
      compile_env: compiled_env,
      compile_env_rule: compile_env_rule(Map.get(build, "compile_env_rule"), compiled_env),
      compile_inputs: inputs,
      foreign_priv: foreign_priv(status, build),
      foreign_priv_rule: foreign_priv_rule(status, build),
      file_manifest: file_manifest(build["file_manifest"]),
      optional_deps: optional_deps(result["optional_deps"]),
      judge_revision: judge_revision(build["judge_revision"]),
      portability_rule: portability_rule(build["portability_rule"]),
      rule1_reason: bounded_reason(build["rule1_reason"]),
      manager: manager(build["manager"]),
      compile_observations: compile_observations(build["compile_observations"]),
      sibling_attempted: sibling_attempted?(result, opts) or backfill?(opts),
      finished_at: parse_datetime(result["finished_at"]),
      # A firmware target's facts (`stage_pinned_target/2`); nil on the
      # toolchain path.
      native: build["native"],
      portable: build["portable"],
      elf_needs: build["elf_needs"],
      toolchain_pkg: build["toolchain_pkg"],
      toolchain_version: build["toolchain_version"],
      otp_full: build["otp_full"],
      system_libs: build["system_libs"]
    }

    with {:ok, row} <-
           PinnedBuild |> Ash.Changeset.for_create(:upsert, attrs) |> Ash.create(domain: @domain) do
      :ok = upsert_artifacts(staged ++ ((sibling && sibling["staged"]) || []))
      :ok = replace_pinned_memberships(row.id, staged)
      with :ok <- Portal.Deterministic.replace(row, sibling), do: {:ok, row}
    end
  end

  # Whether the run tried for the build's deterministic sibling, held or
  # not: the worker writes one, `skipped` with its reason when it could not
  # build it, whenever the run was asked for one (`NccWorker.Deterministic`,
  # each passing target's `NccWorker.FirmwareDeterministic`). The row keeps
  # the attempt, as `Portal.Catalog.DeterministicBuild` stores passes only.
  defp sibling_attempted?(result, %{target: "nerves_system_" <> _ = target}) do
    case result["systems"] do
      %{^target => %{"deterministic_build" => %{}}} -> true
      _ -> false
    end
  end

  defp sibling_attempted?(result, _opts), do: is_map(result["deterministic_build"])

  # Exactly the shas this ingest staged, the whole manifest of a pass.
  defp replace_pinned_memberships(pinned_build_id, staged) do
    shas = staged |> Enum.map(& &1.sha256) |> Enum.uniq() |> Enum.sort()

    Repo.query!(
      """
      DELETE FROM catalog_artifact_memberships
      WHERE pinned_build_id = $1 AND NOT (sha256 = ANY($2::text[]))
      """,
      [dump(pinned_build_id), shas]
    )

    shas
    |> Enum.map(&%{sha256: &1, pinned_build_id: pinned_build_id})
    |> insert_memberships(:upsert_pinned, :unique_pinned_build_sha256)
  end

  # The job's package, which `check_identity/3` has already held the result
  # to. A result without a name is unmappable either way.
  defp package_name(package_info, opts) do
    _ = package_info["name"] || raise "result.json missing package.name"
    opts.package
  end

  defp with_job_version(package_info, %{version: version}),
    do: Map.put(package_info, "version", version)

  defp do_ingest(result, opts, {staged, siblings}, logs) do
    package_info = result |> Map.get("package", %{}) |> with_job_version(opts)
    package_name = package_name(package_info, opts)
    version = package_info["version"] || "unknown"
    systems = Map.get(result, "systems", %{})
    finished_at = parse_datetime(result["finished_at"])
    # Read before the new run exists, which would otherwise be the latest.
    carried = carry_candidates(result, package_name, version, systems)
    overall = overall_status(result, Map.merge(carried_statuses(carried), systems))
    # Once, for both the run row and its triage sightings: a carried ok argus
    # result makes the new run the package's latest argus run, and findings
    # not sighted on it would all turn stale.
    carry? = Map.get(opts, :carry_run_data, false) == true
    result = Map.put(result, "argus", argus_for(result, carried, carry?))

    rule = host_portability_rule(result)

    with {:ok, package} <- upsert_package(package_name, package_info, finished_at),
         hold = rule2_hold(package.id, version, rule, systems),
         {:ok, run} <-
           create_run(result, opts, package.id, version, overall, finished_at, {carried, carry?}),
         :ok <-
           create_system_results(
             systems,
             {run, rule, hold, firmware_world(result, opts)},
             package_name,
             version,
             {staged, siblings},
             logs
           ),
         :ok <- copy_carried(carried, run.id),
         _withdrawn = FirmwareRefusal.withdraw_superseded(package.id, version),
         :ok <- record_triage(package, version, run.id, result["argus"]) do
      {:ok, run}
    end
  end

  # One FindingTriage row per finding of an `ok` argus run, written as a single
  # multi-row upsert: every statement here crosses the build box's ~80ms link
  # to Postgres inside the ingest transaction. Only findings with string
  # analysis and title and a known severity are recorded -- anything else is
  # skipped here rather than handed to Postgres, where an insert error would
  # abort the whole ingest -- and duplicates are collapsed first, because one
  # INSERT ... ON CONFLICT cannot touch the same row twice.
  #
  # Only for a run of the package's latest version: the triage list is of the
  # latest argus run's findings (`Portal.Catalog`'s `latest_argus_runs/0`), and
  # a sighting on an older release's run would mark them all stale.
  defp record_triage(%{latest_version: latest}, version, _run_id, _argus)
       when latest != version,
       do: :ok

  defp record_triage(
         %{name: package_name},
         version,
         run_id,
         %{"status" => "ok", "findings" => findings}
       )
       when is_list(findings) do
    inputs =
      findings
      |> Enum.filter(&triageable?/1)
      |> Enum.map(&sighting(package_name, version, run_id, &1))
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.fingerprint)

    case inputs do
      [] ->
        :ok

      _ ->
        %Ash.BulkResult{status: :success} =
          Ash.bulk_create(inputs, FindingTriage, :sighting,
            domain: @domain,
            batch_size: @max_triage_batch,
            upsert?: true,
            upsert_identity: :unique_fingerprint,
            upsert_fields: [:severity, :line, :finding, :last_seen_version, :last_seen_run_id],
            return_errors?: true,
            stop_on_error?: true
          )

        :ok
    end
  end

  defp record_triage(_package, _version, _run_id, _argus), do: :ok

  defp sighting(package_name, version, run_id, finding) do
    %{
      fingerprint: FindingTriage.fingerprint(package_name, finding),
      package_name: package_name,
      analysis: finding["analysis"],
      severity: finding["severity"],
      title: finding["title"],
      file: if(is_binary(finding["file"]), do: finding["file"]),
      line: if(is_integer(finding["line"]), do: finding["line"]),
      finding: finding,
      first_seen_version: version,
      last_seen_version: version,
      last_seen_run_id: run_id
    }
  end

  defp triageable?(%{"analysis" => a, "severity" => s, "title" => t})
       when is_binary(a) and is_binary(t) and s in ["error", "warning", "info"],
       do: true

  defp triageable?(_), do: false

  # The package's latest version only ever moves up (`LatestRun`): a run of
  # an older release leaves the row as it is, since every field written here
  # describes the latest version. The row is read `FOR UPDATE`, so two ingests
  # of one package decide in turn, each on the other's committed row.
  defp upsert_package(name, info, last_run_at) do
    version = info["version"]

    attrs = %{
      description: info["description"],
      latest_version: version,
      last_run_at: last_run_at,
      native_components: info["native_components"]
    }

    case locked_package(name) do
      nil ->
        Package
        |> Ash.Changeset.for_create(:upsert, Map.put(attrs, :name, name))
        |> Ash.create(domain: @domain)

      package ->
        if LatestRun.supersedes?(version, package.latest_version) or
             not run_of_latest?(package) do
          package |> Ash.Changeset.for_update(:ingested, attrs) |> Ash.update(domain: @domain)
        else
          {:ok, package}
        end
    end
  end

  defp locked_package(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(domain: @domain)
  end

  # Only asked when the package has a latest version (`LatestRun.supersedes?/2`
  # takes any version over none).
  defp run_of_latest?(package) do
    Repo.exists?(
      from(r in "catalog_runs",
        where:
          r.package_id == type(^package.id, Ecto.UUID) and
            r.version_tested == ^package.latest_version
      )
    )
  end

  # A worker that predates argus sends nothing; anything that is not a map is
  # not something the package page can read either, and must not fail ingest.
  defp argus_map(%{} = argus), do: argus
  defp argus_map(_), do: nil

  # All or nothing, like `NccWorker.DepsLock`. The manifest publishes this so a
  # client can check its own lock against it, and a subset of the build's tree
  # would let a client match a build it should not. The build container wrote
  # it, and the package under test runs inside that container, so a malformed
  # entry stores no lock at all rather than the well-formed rest. The ingest
  # itself still succeeds: the run's results stand, its files just are not
  # offered for lock matching. Extra keys inside a well-formed entry carry no
  # meaning and are stripped.
  defp deps_lock(%{} = deps_lock) do
    Enum.reduce_while(deps_lock, %{}, fn
      {name, %{"version" => version, "checksum" => checksum}}, acc
      when is_binary(name) and is_binary(version) and is_binary(checksum) ->
        {:cont, Map.put(acc, name, %{"version" => version, "checksum" => checksum})}

      _entry, _acc ->
        {:halt, nil}
    end)
  end

  defp deps_lock(_), do: nil

  defp package_checksum(v) when is_binary(v), do: v
  defp package_checksum(_), do: nil

  # The package's declared dependencies (`NccWorker.DepsLock.declared/2`),
  # kept only whole and well-formed: a client ranks builds by it, and a
  # partial list would rank wrongly. Like deps_lock/1, a malformed item
  # stores nothing at all and the ingest still succeeds; extra keys inside a
  # well-formed item are stripped. An empty list says no more than a missing
  # one, so it is stored as nil too.
  defp declared([_ | _] = list) do
    Enum.reduce_while(list, [], fn item, acc ->
      case declared_item(item) do
        nil -> {:halt, nil}
        kept -> {:cont, [kept | acc]}
      end
    end)
    |> then(fn
      nil -> nil
      acc -> Enum.reverse(acc)
    end)
  end

  defp declared(_), do: nil

  defp declared_item(%{"app" => a, "name" => n, "requirement" => r, "optional" => o})
       when is_binary(a) and is_binary(n) and is_binary(r) and is_boolean(o),
       do: %{"app" => a, "name" => n, "requirement" => r, "optional" => o}

  defp declared_item(_), do: nil

  # Same contract as deps_lock/1: all or nothing per system, the ingest
  # itself still succeeds. Task I: an entry whose value is not plain, small
  # ETF (`Compatibility.RecordedValue.acceptable?/1`) drops the whole list,
  # the same as a malformed one, because the container that wrote
  # result.json could have recorded any term the package set in its own
  # application env. The literal `"unrecordable"`
  # (`Compatibility.CompileInputs`) is kept: it matches nothing on any
  # client. `context` (`{package, version}`) is used only for the warning;
  # never the value itself.
  defp compile_env(list, context \\ nil)

  defp compile_env(list, context) when is_list(list) do
    Enum.reduce_while(list, [], fn
      %{"app" => app, "path" => path, "value" => value}, acc
      when is_binary(app) and is_list(path) and is_binary(value) ->
        cond do
          not Enum.all?(path, &is_binary/1) ->
            {:halt, nil}

          not CompileInputs.value?(value) ->
            warn_unrecordable(context)
            {:halt, nil}

          true ->
            {:cont, [%{"app" => app, "path" => path, "value" => value} | acc]}
        end

      _, _ ->
        {:halt, nil}
    end)
    |> then(fn
      nil -> nil
      acc -> Enum.reverse(acc)
    end)
  end

  defp compile_env(_list, _context), do: nil

  # A build's compile-time inputs (`Compatibility.CompileInputs`), checked
  # whole. A malformed list still says the compile read something it could
  # not record: it is stored as one `config_unrecorded` item, which needs a
  # check, so format 1 and format 2's `builds` both leave the build out (none
  # would make it a plain build there). The build's `compile_env` is dropped
  # too, so format 2 leaves it out of `builds_with_inputs` as well. `context`
  # is used only for the warning; never a value.
  @malformed_inputs [%{"kind" => "config_unrecorded"}]

  defp inputs_and_env(raw, context) do
    case CompileInputs.validate(raw["compile_inputs"]) do
      {:ok, inputs} ->
        {inputs, compile_env(raw["compile_env"], context)}

      :error ->
        warn_inputs(context)
        {@malformed_inputs, nil}
    end
  end

  defp warn_inputs({package, version}),
    do:
      Logger.warning(
        "compile_inputs malformed for #{package} #{version}: stored as config_unrecorded and " <>
          "compile_env dropped, so neither format publishes the build"
      )

  defp warn_unrecordable(nil), do: :ok

  defp warn_unrecordable({package, version}) do
    Logger.warning(
      "compile_env dropped for #{package} #{version}: an entry's value is not plain, small ETF"
    )
  end

  # The R5 mark only next to a `compile_env` this ingest keeps: a mark on a
  # list it rejected would exempt a build from the withheld list with no
  # match conditions to show for it. A missing or null mark stays nil.
  # `resolved_compile_env` is the already-decoded `compile_env/2` result for
  # this same build or system, not the raw `result.json` list: every caller
  # computes `compile_env/2` once and reuses it here, rather than deciding
  # the mark from a second, separate decode of the same values.
  defp compile_env_rule(rule, resolved_compile_env) when is_integer(rule) and rule in 1..9 do
    if resolved_compile_env == nil, do: nil, else: rule
  end

  defp compile_env_rule(_rule, _resolved_compile_env), do: nil

  # Only a `pure_elixir` result traces its compile and so records its config
  # reads; a firmware result never does, so a mark on one is dropped rather
  # than stored on a row no selector would exempt.
  defp system_compile_env_rule("pure_elixir", sys, resolved_compile_env),
    do: compile_env_rule(Map.get(sys, "compile_env_rule"), resolved_compile_env)

  defp system_compile_env_rule(_system_pkg, _sys, _resolved_compile_env), do: nil

  # A revocation of what rule 2 alone published sticks: when a `pure_elixir`
  # result of this version was revoked that way
  # (`Portal.Precompiled.ToolchainRevocation`), a new rule-2 `pure_elixir`
  # result of it is stored withdrawn too, with the same reason and the newest
  # such revocation's timestamp, so that call's `undo/1` puts it back with
  # the rest. nil (publish as usual) otherwise.
  @rule2_hold_sql """
  SELECT max(s.unpublished_at)
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  WHERE r.package_id = $1 AND r.version_tested = $2
    AND s.system_pkg = 'pure_elixir' AND s.unpublished_reason = $3
  """

  defp rule2_hold(package_id, version, 2, %{"pure_elixir" => _}) do
    %{rows: [[at]]} =
      Repo.query!(@rule2_hold_sql, [
        Ecto.UUID.dump!(package_id),
        version,
        SystemResult.rule2_revocation()
      ])

    if at, do: DateTime.from_naive!(at, "Etc/UTC")
  end

  defp rule2_hold(_package_id, _version, _rule, _systems), do: nil

  # The rule that judged a `pure_elixir` result's publication, from the
  # result's top-level `host_portability`; only `pure_elixir` stores it.
  defp host_portability_rule(result) do
    case Map.get(result, "host_portability") do
      %{} = hp -> portability_rule(Map.get(hp, "portability_rule"))
      _ -> nil
    end
  end

  defp create_run(result, opts, package_id, version, overall, finished_at, {carried, carry?}) do
    Run
    |> Ash.Changeset.for_create(:create, %{
      run_id: opts.run_id,
      package_id: package_id,
      version_tested: version,
      image_digest: opts.image_digest,
      overall_status: overall,
      footprint: footprint_for(result, carried, carry?),
      toolchain: result["toolchain"],
      argus: result["argus"],
      deps_lock: deps_lock(result["deps_lock"]),
      package_checksum: package_checksum(result["package_checksum"]),
      declared: declared(result["declared"]),
      log: run_log(overall, opts),
      started_at: parse_datetime(result["started_at"]),
      finished_at: finished_at,
      scan_request_id: Map.get(opts, :scan_request_id),
      builder_id: Map.get(opts, :builder_id),
      arch: Map.get(opts, :arch)
    })
    |> Ash.create(domain: @domain)
  end

  # An argus-only run builds no firmware, and the worker reports that as an
  # empty footprint with zero totals rather than none at all, so it is the
  # scope that says the measurement is missing. A targets run built firmware
  # and measured it, so it keeps its own.
  defp footprint_for(%{"scope" => "argus_only"}, %{footprint: previous}, _carry?), do: previous

  # A targets run stopped by the wall clock (`Portal.Catalog.BuildTimeout`,
  # which passes the `:carry_run_data` opt) measured nothing and ran no argus,
  # so it keeps the previous run's footprint and argus result. The flag is an
  # opt, never read from the result: `result.json` is written by a container
  # running package code. A real run keeps its own values, nil included.
  defp footprint_for(_result, %{footprint: previous}, true), do: previous
  defp footprint_for(result, _carried, _carry?), do: get_in(result, ["package", "footprint"])

  defp argus_for(_result, %{argus: previous}, true), do: argus_map(previous)
  defp argus_for(result, _carried, _carry?), do: argus_map(result["argus"])

  @partial_scopes ["targets", "argus_only"]

  # A partial run rebuilt only some systems. The rest are copied from the
  # newest run of the same version, so the run stays complete: of the latest
  # version, it is the latest run, which every page, badge and API reads as
  # the whole picture, and of an older release, it is the run the
  # precompiled manifests serve for that version. Across versions nothing
  # carries: an old version's target results say nothing about the new one.
  defp carry_candidates(%{"scope" => scope}, package_name, version, systems)
       when scope in @partial_scopes do
    case previous_run(package_name, version) do
      %{id: run_id, footprint: footprint, argus: argus} ->
        rows =
          Repo.all(
            from(s in "catalog_system_results",
              where: s.run_id == type(^run_id, Ecto.UUID),
              where: s.system_pkg not in type(^Map.keys(systems), {:array, :string}),
              select: %{
                id: type(s.id, Ecto.UUID),
                system_pkg: s.system_pkg,
                status: s.status,
                carried_from_run_id: type(s.carried_from_run_id, Ecto.UUID)
              }
            )
          )

        %{run_id: run_id, footprint: footprint, argus: argus, rows: rows}

      _ ->
        nil
    end
  end

  defp carry_candidates(_result, _package_name, _version, _systems), do: nil

  # The newest run of the version (`LatestRun.of_version/2`): newest
  # `finished_at`, then newest `inserted_at`, plain `DESC`. Of the latest
  # version it is the latest run; carrying from any other run would copy
  # rows the pages were not showing as current.
  defp previous_run(package_name, version) do
    Repo.one(
      from([r] in LatestRun.of_version(package_name, version),
        select: %{id: type(r.id, Ecto.UUID), footprint: r.footprint, argus: r.argus}
      )
    )
  end

  # Raw status strings, the shape `overall_status/2` parses from result.json.
  defp carried_statuses(nil), do: %{}

  defp carried_statuses(%{rows: rows}),
    do: Map.new(rows, &{&1.system_pkg, %{"status" => &1.status}})

  # Copies each carried row whole -- every column but id, run_id and
  # timestamps -- plus its artifact memberships and stored log, so the
  # precompiled API and the log page behave as if the row had been built in
  # this run. `carried_from_run_id` keeps pointing at the run that built it,
  # across any chain of partial runs. A withdrawn result stays withdrawn in
  # its copies, and a marked one marked.
  #
  # Three statements however many systems carry, each joined against the
  # old-to-new id pairs: every statement crosses the build box's ~80ms link
  # to Postgres inside the ingest transaction.
  defp copy_carried(nil, _run_id), do: :ok
  defp copy_carried(%{rows: []}, _run_id), do: :ok

  defp copy_carried(%{run_id: from_run, rows: rows}, run_id) do
    old_ids = Enum.map(rows, &dump(&1.id))
    new_ids = Enum.map(rows, fn _ -> dump(Ecto.UUID.generate()) end)
    built_in = Enum.map(rows, &dump(&1.carried_from_run_id || from_run))

    Repo.query!(
      """
      INSERT INTO catalog_system_results
        (id, run_id, system_pkg, system_version, status, firmware_size_bytes, duration_sec,
         phase_timings, hex_version_tested, beam_scan, compile_env, compile_inputs,
         dependency_scans, log_path, log_tail, failure_category, carried_from_run_id, deps_lock,
         unpublished_at, compile_env_rule, portability_rule, unpublished_reason, native, portable, elf_needs,
         toolchain_pkg, toolchain_version, otp_full, published_variants, build_root, inserted_at,
         updated_at)
      SELECT m.new_id, $1, s.system_pkg, s.system_version, s.status, s.firmware_size_bytes,
             s.duration_sec, s.phase_timings, s.hex_version_tested, s.beam_scan, s.compile_env,
             s.compile_inputs, s.dependency_scans, s.log_path, s.log_tail, s.failure_category, m.built_in,
             s.deps_lock, s.unpublished_at, s.compile_env_rule, s.portability_rule,
             s.unpublished_reason, s.native, s.portable, s.elf_needs, s.toolchain_pkg,
             s.toolchain_version, s.otp_full, s.published_variants, s.build_root,
             now() AT TIME ZONE 'utc',
             now() AT TIME ZONE 'utc'
      FROM catalog_system_results s
      JOIN unnest($2::uuid[], $3::uuid[], $4::uuid[]) AS m(old_id, new_id, built_in)
        ON m.old_id = s.id
      """,
      [dump(run_id), old_ids, new_ids, built_in]
    )

    Repo.query!(
      """
      INSERT INTO catalog_artifact_memberships (id, system_result_id, sha256, inserted_at)
      SELECT gen_random_uuid(), m.new_id, a.sha256, now() AT TIME ZONE 'utc'
      FROM catalog_artifact_memberships a
      JOIN unnest($1::uuid[], $2::uuid[]) AS m(old_id, new_id) ON m.old_id = a.system_result_id
      """,
      [old_ids, new_ids]
    )

    Repo.query!(
      """
      INSERT INTO catalog_system_logs
        (id, system_result_id, body, byte_size, truncated, inserted_at, updated_at)
      SELECT gen_random_uuid(), m.new_id, l.body, l.byte_size, l.truncated,
             now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
      FROM catalog_system_logs l
      JOIN unnest($1::uuid[], $2::uuid[]) AS m(old_id, new_id) ON m.old_id = l.system_result_id
      """,
      [old_ids, new_ids]
    )

    :ok
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  # A passing run's `runner.log` is 100 KB of "Generated <app> app" that nothing
  # in this repo reads: `catalog_runs.log` has no reader on any page, API or
  # query, and passing runs are 97% of the bytes stored there (262 MB of 270 MB
  # in production). Failures keep theirs, because that is the one case where
  # somebody eventually asks what the runner was doing.
  #
  # `Portal.Workers.LogRetention` clears what earlier ingests already stored.
  defp run_log(:pass, _opts), do: nil

  defp run_log(_overall, opts), do: Map.get(opts, :log)

  defp create_system_results(systems, run, package_name, version, staged, logs) do
    Enum.reduce_while(systems, :ok, fn {system_pkg, sys}, _acc ->
      case create_system_result(system_pkg, sys, run, package_name, version, staged, logs) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_system_result(
         system_pkg,
         sys,
         {run, rule, hold, world},
         package_name,
         version,
         {staged, siblings},
         logs
       ) do
    status = Compatibility.Types.parse_status(sys["status"])
    held_at = if system_pkg == "pure_elixir", do: hold
    {inputs, compiled_env} = inputs_and_env(sys, {package_name, version})
    {toolchain_pkg, toolchain_version} = system_toolchain(sys["toolchain"])

    variants =
      system_pkg
      |> published_variants(sys, {package_name, version})
      |> gate_world(sys, world)

    result =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: system_pkg,
        system_version: sys["system_version"],
        status: status,
        firmware_size_bytes: sys["firmware_size_bytes"],
        duration_sec: sys["duration_sec"],
        phase_timings: sys["phase_timings"],
        hex_version_tested: version,
        beam_scan: sys["beam_scan"],
        compile_env: compiled_env,
        compile_inputs: inputs,
        dependency_scans: drop_file_manifests(sys["dependency_scans"]),
        log_path: nil,
        log_tail: sys["log_tail"],
        failure_category: Portal.Catalog.FailureClassifier.classify(sys),
        deps_lock: deps_lock(sys["deps_lock"]),
        compile_env_rule: system_compile_env_rule(system_pkg, sys, compiled_env),
        portability_rule: if(system_pkg == "pure_elixir", do: rule),
        unpublished_at: held_at,
        unpublished_reason: if(held_at, do: SystemResult.rule2_revocation()),
        toolchain_pkg: toolchain_pkg,
        toolchain_version: toolchain_version,
        otp_full: fact_string(sys["otp_full"]),
        published_variants: variants,
        build_root: build_root(sys["build_root"])
      })
      |> Ash.create(domain: @domain)

    case result do
      {:ok, system_result} ->
        staged_blobs = Map.get(staged, system_pkg, [])
        sibling = Map.get(siblings, system_pkg)

        :ok = upsert_artifacts(staged_blobs ++ ((sibling && sibling["staged"]) || []))
        :ok = upsert_memberships(system_result.id, sys, variants, staged_blobs)

        :ok = maybe_store_log(system_result, system_pkg, Map.get(logs, system_pkg))

        # A firmware target's deterministic sibling, owned by its row.
        with :ok <-
               Portal.Deterministic.store(system_result, sibling, sibling_run(run, version)),
             do: {:ok, system_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sibling_run(run, version),
    do: %{package_id: run.package_id, version: version, finished_at: run.finished_at}

  # The worker writes `build_root` only on a judged firmware target; anything
  # but a map is dropped rather than stored as a verdict.
  defp build_root(%{} = build_root), do: build_root
  defp build_root(_), do: nil

  # Strip `footprint.file_manifest` out of every dependency scan before it is
  # persisted.
  #
  # Each dependency's manifest lists every ebin and priv file it produced —
  # path, mode, size and sha256 per file. Measured against production on
  # 2026-09-10 that is 75% of the 1,501 MB this column holds, and it is largely
  # the same list stored again and again: a given dependency version built for a
  # given Nerves target yields the same manifest for every package that depends
  # on it, which across the catalog is on the order of seventeen copies each.
  #
  # The manifest has exactly one consumer, `collect_shas/1`. That runs inside
  # `stage_artifacts/2`, before the transaction opens, against the in-memory
  # `result.json` — never against this column. Every sha it finds is already
  # persisted as a `catalog_artifacts` row. Nothing in the portal reads
  # `dependency_scans` back out of Postgres at all; the precompiled manifest API
  # builds from `beam_scan`, which is the package's own files and stays whole.
  #
  # Everything else in a dependency scan is kept: flags, errors, evidence,
  # languages, protocols, beam_count, start_modules, and the footprint totals.
  defp drop_file_manifests(scans) when is_map(scans) do
    Map.new(scans, fn
      {dep, %{"footprint" => footprint} = scan} when is_map(footprint) ->
        {dep, Map.put(scan, "footprint", Map.delete(footprint, "file_manifest"))}

      {dep, scan} ->
        {dep, scan}
    end)
  end

  defp drop_file_manifests(other), do: other

  # The other builds a passing firmware target publishes beside its own
  # (`NccWorker.OptionalDepsTargets`, result.json `published_variants`).
  # Today only "without": the target's first build, made without the
  # package's optional deps, under the run's lock. Each is kept whole or not
  # at all, like `deps_lock/1` and `compile_env/2`: a variant whose lock or
  # compile_env is malformed could not be matched safely, so it is dropped
  # and the target publishes its own build alone, as before variants
  # existed. Only the file manifest of its beam scan is stored. A result
  # without the key (every worker before it) stores nil.
  #
  # A firmware world build (`NccWorker.WorldTargets`, "world_<name>") is
  # kept only by `gate_world/3`.
  @variants ["without" | Compatibility.Worlds.firmware_variants()]

  defp published_variants(
         system_pkg,
         %{"status" => "pass", "published_variants" => list},
         context
       )
       when system_pkg not in ["host", "pure_elixir"] and is_list(list) do
    list
    |> Enum.flat_map(&published_variant(&1, context))
    |> Enum.uniq_by(& &1["variant"])
    |> case do
      [] -> nil
      variants -> variants
    end
  end

  defp published_variants(_system_pkg, _sys, _context), do: nil

  defp published_variant(
         %{
           "variant" => variant,
           "beam_scan" => %{"footprint" => %{"file_manifest" => %{} = manifest}}
         } = raw,
         context
       )
       when variant in @variants do
    with %{} = lock <- deps_lock(raw["deps_lock"]),
         env when is_list(env) <- compile_env(raw["compile_env"], context) do
      [
        %{
          "variant" => variant,
          "file_manifest" => Map.take(manifest, ["ebin", "priv"]),
          "compile_env" => env,
          "deps_lock" => lock
        }
      ]
    else
      _ -> []
    end
  end

  defp published_variant(_raw, _context), do: []

  # The firmware world variant the job asked for and the run says it built:
  # `opts.firmware_world` (the Build job's arg) and the result's echo
  # `"world:<name>"` must agree. nil keeps no world variant at all, so a run
  # from an image or a job without the world never publishes one.
  defp firmware_world(result, opts) do
    with name when is_binary(name) <- Map.get(opts, :firmware_world),
         {:ok, variant} <- Compatibility.Worlds.firmware_variant(name),
         echo when echo == "world:" <> name <- result["firmware_world"] do
      %{variant: variant, run_lock: deps_lock(result["deps_lock"])}
    else
      _ -> nil
    end
  end

  # Keeps a world variant only when it is the one `firmware_world/2`
  # allows and its closure differs from the build the row publishes (its
  # own lock, or the run's) and from the build without: an equal closure is
  # the same build to a client, which matches on the closure's names.
  defp gate_world(nil, _sys, _world), do: nil

  defp gate_world(variants, sys, world) do
    others =
      for(%{"variant" => "without", "deps_lock" => lock} <- variants, do: names(lock))
      |> then(&[names(deps_lock(sys["deps_lock"]) || (world && world.run_lock)) | &1])

    variants
    |> Enum.filter(fn
      %{"variant" => "without"} -> true
      %{"variant" => name, "deps_lock" => lock} -> world_kept?(world, name, lock, others)
    end)
    |> case do
      [] -> nil
      kept -> kept
    end
  end

  # The world only adds to the run's closure (`NccWorker.WorldTargets`):
  # every run-lock entry is in its lock, at the same release.
  defp world_kept?(%{variant: name, run_lock: %{} = run_lock}, name, lock, others),
    do: Map.take(lock, Map.keys(run_lock)) == run_lock and names(lock) not in others

  defp world_kept?(_world, _name, _lock, _others), do: false

  defp names(%{} = lock), do: lock |> Map.keys() |> Enum.sort()
  defp names(_lock), do: nil

  # `Portal.Catalog.BuildTimeout` keeps the log of the one target the wall
  # clock cut off: the others it reached finished their builds, and their
  # logs say nothing about the timeout.
  defp log_systems(systems, %{log_systems: names}) when is_list(names),
    do: Map.take(systems, names)

  defp log_systems(systems, _opts), do: systems

  # Read and sanitize every failed system's log BEFORE the transaction opens,
  # for the same reason the artifact blobs are moved first: filesystem work does
  # not belong on a held database connection. Doing it inline meant an ingest
  # whose logs were slow to read spent that time holding a connection out of a
  # pool sized for row writes.
  #
  # Logs are stored for failures only. Passing builds are 97% of the log bytes
  # and almost none of the value; warnings from passing builds are phase 2 and
  # are extracted per line rather than stored whole.
  defp stage_logs(_systems, nil), do: %{}

  defp stage_logs(systems, output_dir) do
    systems
    |> Enum.filter(fn {_system_pkg, sys} ->
      Compatibility.Types.parse_status(sys["status"]) in [:fail, :error]
    end)
    |> Enum.flat_map(fn {system_pkg, _sys} ->
      case stage_log(system_pkg, output_dir) do
        {:ok, log} -> [{system_pkg, log}]
        :skip -> []
      end
    end)
    |> Map.new()
  end

  defp stage_log(system_pkg, output_dir) do
    if traversal?(system_pkg) do
      # `system_pkg` is a key from the worker's result.json, and /out is a
      # read-write bind mount in a container that runs untrusted package code.
      # Nothing today can steer this key, but the bytes at the path it builds
      # become a publicly readable log body, so refuse a key that could name a
      # path outside the logs dir. This check covers the *name* only; the file
      # it resolves to is checked by `LogSanitizer.system_log_file/1`.
      Logger.warning("Refusing to read a build log for suspicious system #{inspect(system_pkg)}")
      :skip
    else
      path = Path.join([output_dir, "logs", "#{system_pkg}.log"])
      read_log(path, system_pkg)
    end
  end

  defp read_log(path, system_pkg) do
    case LogSanitizer.system_log_file(path) do
      {:ok, log} ->
        {:ok, log}

      {:error, {:not_regular, type}} ->
        Logger.warning("Refusing a non-regular build log at #{path} (#{type})")
        :skip

      {:error, reason} ->
        # Never fail an ingest over a log. A failed ingest burns an Oban attempt
        # and, at exhaustion, throws away a completed multi-gigabyte build.
        Logger.warning("No build log at #{path} for #{system_pkg}: #{inspect(reason)}")
        :skip
    end
  end

  defp traversal?(system_pkg) when is_binary(system_pkg),
    do: String.contains?(system_pkg, ["/", "\\", ".."])

  defp traversal?(_system_pkg), do: true

  defp maybe_store_log(_system_result, _system_pkg, nil), do: :ok

  defp maybe_store_log(system_result, system_pkg, sanitized),
    do: insert_log(system_result, system_pkg, sanitized)

  # A log must never fail an ingest: a failed ingest burns an Oban attempt and,
  # at exhaustion, discards a completed multi-gigabyte build. This insert runs
  # inside the ingest transaction, and in Postgres one failed statement aborts
  # the whole transaction — every later statement is refused until it ends — so
  # "never fail" needs more than an error branch.
  #
  # An ambient transaction is required, not optional: outside one, `SAVEPOINT`
  # is itself an error, the `catch` below swallows it, and every log is silently
  # dropped with a warning. The only caller is `create_system_result/7`, inside
  # the transaction `ingest/2` opens.
  #
  # Nothing about the log's *content* can trigger that: the sanitizer guarantees
  # valid UTF-8 with no NUL bytes and caps the body at 800 KB, and
  # `system_result` was inserted moments ago, so the unique index cannot fire.
  # Its *transport* can: a pool checkout timeout, a connection dropped over the
  # ~80ms private network link to Postgres, or a statement timeout all abort the
  # statement the same way. Hence the SAVEPOINT, which scopes the damage to this
  # one row.
  #
  # Two details are measured rather than assumed. A nested `Repo.transaction/1`
  # is *not* a savepoint — DBConnection runs a nested transaction on the same
  # connection and only marks it failed until the outermost call rolls back, so
  # with one the insert after a failed log still failed and the ingest still
  # returned `{:error, :rollback}`. And Ash signals a data-layer error from
  # inside a transaction by throwing `{DBConnection, ref, changeset}` rather
  # than returning `{:error, reason}`, so the `catch` is what actually stops it.
  defp insert_log(system_result, system_pkg, sanitized) do
    try do
      Repo.query!("SAVEPOINT #{@log_savepoint}")

      case create_system_log(system_result, sanitized) do
        {:ok, _log} ->
          Repo.query!("RELEASE SAVEPOINT #{@log_savepoint}")

        {:error, reason} ->
          Logger.warning(
            "Could not store the log for #{system_pkg}: #{inspect(reason, limit: 3)}"
          )

          Repo.query!("ROLLBACK TO SAVEPOINT #{@log_savepoint}")
          Repo.query!("RELEASE SAVEPOINT #{@log_savepoint}")
      end
    catch
      kind, reason ->
        Logger.warning(
          "Could not store the log for #{system_pkg}: #{inspect({kind, reason}, limit: 3)}"
        )
    end

    :ok
  end

  defp create_system_log(system_result, sanitized) do
    SystemLog
    |> Ash.Changeset.for_create(:create, %{
      system_result_id: system_result.id,
      body: sanitized.body,
      byte_size: sanitized.byte_size,
      truncated: sanitized.truncated
    })
    |> Ash.create(domain: @domain)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Move every content-addressed blob referenced by the manifests out of
  # files_dir into the artifact store, returning the pending Artifact rows keyed
  # by system package. Filesystem only: no database connection is held here, and
  # nothing below may acquire one.
  defp stage_artifacts(systems, files_dir) do
    Map.new(systems, fn {system_pkg, sys} ->
      {system_pkg, stage_system_artifacts(sys, files_dir)}
    end)
  end

  defp stage_system_artifacts(sys, files_dir) do
    sys
    |> collect_shas()
    |> stage_shas(files_dir)
  end

  # Moves each named blob from files_dir into the store; the pending Artifact
  # rows of those that made it. Filesystem only, like `stage_artifacts/2`.
  defp stage_shas(shas, files_dir) do
    Enum.flat_map(shas, fn sha ->
      source = Path.join(files_dir, sha)

      case ArtifactStore.put(sha, source) do
        {:ok, %{disk_path: disk_path, byte_size: bytes}} ->
          [%{sha256: sha, byte_size: bytes, disk_path: disk_path}]

        {:error, :source_missing} ->
          Logger.debug("Artifact blob #{sha} not present in files_dir; skipping")
          []

        {:error, reason} ->
          Logger.warning("Failed to store artifact #{sha}: #{inspect(reason)}")
          []
      end
    end)
  end

  # One statement per batch of blobs, not one per blob.
  #
  # A single system's manifest carries on the order of a thousand
  # content-addressed BEAM files, and this used to be a row-at-a-time
  # `Ash.create/2`: ~950 sequential round trips, all inside the ingest
  # transaction, which blew the same 15s checkout limit that `ingest/2`
  # describes. The blobs themselves are ~15MB total, so the cost was never
  # volume, only the number of round trips.
  # Record which of this system's *own* manifest files are now in the store.
  #
  # Scoped to `beam_scan` on purpose. `stage_artifacts/2` also stores the blobs
  # of the package's dependencies, but their per-file manifests are stripped
  # before persisting (`drop_file_manifests/1`), so there is nothing to publish
  # them against — those blobs stay in the registry without a membership row.
  # The precompiled API builds from `beam_scan`, which is exactly this set.
  #
  # Intersected with what was actually staged, so a membership can never point
  # at a blob the store does not hold, and de-duplicated because a single
  # INSERT cannot touch the same conflict target twice.
  #
  # A published variant's files (`published_variants/3`) are the row's too:
  # one set of memberships per target, the union of its builds, so the blob
  # endpoint serves a variant's files under exactly the row's gate, and a
  # blob both builds share is one membership.
  defp upsert_memberships(system_result_id, sys, variants, staged) do
    stored = MapSet.new(staged, & &1.sha256)

    sys["beam_scan"]
    |> shas_from_scan()
    |> Kernel.++(Enum.flat_map(variants || [], &shas_from_manifest(&1["file_manifest"])))
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(stored, &1))
    |> Enum.sort()
    |> Enum.map(&%{sha256: &1, system_result_id: system_result_id})
    |> insert_memberships(:upsert, :unique_system_result_sha256)
  end

  defp insert_memberships([], _action, _identity), do: :ok

  defp insert_memberships(entries, action, identity) do
    entries
    |> Ash.bulk_create(ArtifactMembership, action,
      domain: @domain,
      upsert?: true,
      upsert_identity: identity,
      upsert_fields: [:sha256],
      return_errors?: true,
      stop_on_error?: false,
      transaction: false
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("Artifact membership insert failed: #{inspect(errors)}")
        :ok
    end
  end

  defp upsert_artifacts([]), do: :ok

  defp upsert_artifacts(entries) do
    entries
    |> Enum.uniq_by(& &1.sha256)
    |> reject_already_registered()
    |> Enum.sort_by(& &1.sha256)
    |> bulk_upsert_artifacts()
  end

  defp reject_already_registered(entries) do
    shas = Enum.map(entries, & &1.sha256)

    registered =
      Artifact
      |> Ash.Query.filter(sha256 in ^shas)
      |> Ash.Query.select([:sha256])
      |> Ash.read!(domain: @domain)
      |> MapSet.new(& &1.sha256)

    Enum.reject(entries, &MapSet.member?(registered, &1.sha256))
  end

  defp bulk_upsert_artifacts([]), do: :ok

  defp bulk_upsert_artifacts(entries) do
    entries
    |> Ash.bulk_create(Artifact, :upsert,
      domain: @domain,
      upsert?: true,
      upsert_identity: :unique_sha256,
      upsert_fields: [:byte_size, :disk_path],
      return_errors?: true,
      stop_on_error?: false,
      transaction: false
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Failed to register #{length(errors)} of #{length(entries)} artifacts; " <>
            "first error: #{inspect(List.first(errors))}"
        )

        :ok
    end
  end

  # Collect unique sha256s from a system result's beam_scan + dependency_scans
  # file manifests.
  defp collect_shas(sys) do
    package_scan = sys["beam_scan"]
    dep_scans = sys["dependency_scans"] || %{}

    # As the worker wrote them: `published_variants/3` decides later which
    # are kept, and a staged blob nothing claims is only a registry entry.
    variant_scans =
      case sys["published_variants"] do
        list when is_list(list) -> Enum.map(list, &(is_map(&1) && &1["beam_scan"]))
        _ -> []
      end

    dep_scan_list =
      case dep_scans do
        m when is_map(m) -> Map.values(m)
        _ -> []
      end

    [package_scan | dep_scan_list ++ variant_scans]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&shas_from_scan/1)
    |> Enum.uniq()
  end

  defp shas_from_scan(scan) when is_map(scan),
    do: scan |> get_in(["footprint", "file_manifest"]) |> shas_from_manifest()

  defp shas_from_scan(_), do: []

  # The shas of a `%{"ebin" => [entry], "priv" => [entry]}` file manifest, the
  # shape of a beam scan's `footprint.file_manifest` and of a toolchain build's
  # `file_manifest`.
  defp shas_from_manifest(manifest) when is_map(manifest) do
    (manifest_entries(manifest, "ebin") ++ manifest_entries(manifest, "priv"))
    |> Enum.map(fn entry -> is_map(entry) && entry["sha256"] end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp shas_from_manifest(_), do: []

  defp manifest_entries(manifest, key) do
    case Map.get(manifest, key) do
      entries when is_list(entries) -> entries
      _ -> []
    end
  end

  # Derive the overall status. A top-level forced_status (gleam/retired) wins;
  # otherwise pass if any system passed, then fail/error/skipped, else unknown.
  defp overall_status(%{"forced_status" => s}, _systems) when is_binary(s),
    do: Compatibility.Types.parse_status(s)

  defp overall_status(result, systems) do
    partial? = result["scope"] in @partial_scopes

    case Map.pop(systems, "host") do
      # A partial run with nothing to carry -- no previous run of this
      # version -- built no target at all; its host compile is the only
      # verdict it has. A full run always builds its targets, so it keeps
      # the rule below.
      {%{} = host, targets} when partial? and targets == %{} ->
        Compatibility.Types.parse_status(host["status"])

      {_host, targets} ->
        statuses = Enum.map(Map.values(targets), &Compatibility.Types.parse_status(&1["status"]))
        Enum.find([:pass, :fail, :error, :skipped], :unknown, &(&1 in statuses))
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_other), do: nil
end
