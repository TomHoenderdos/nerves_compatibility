defmodule NccWorker.Worker do
  @moduledoc """
  Main worker implementation that evaluates a package against Nerves systems.
  """

  alias NccWorker.{
    AppFile,
    Argus,
    BeamScan,
    BuildCache,
    BuildSelection,
    DepsGetClassifier,
    DepsLock,
    EgressProbe,
    Footprint,
    HexCache,
    HexHome,
    HexMetadata,
    HostTrace,
    LockPolicy,
    LogTail,
    NervesCache,
    OptionalDepsTargets,
    Portability,
    Portability.ConfigReads,
    Project,
    RunScope,
    Scanner,
    SeedGate,
    Systems,
    WarmNerves
  }

  alias Compatibility.Portability, as: PortabilityReasons

  @forced_skip_system "forced@admin@unknown"

  @type input :: %{
          required(:run_id) => String.t(),
          required(:image) => %{
            required(:name) => String.t(),
            required(:digest) => String.t()
          },
          # Absent only for "warm_nerves", which builds no package.
          optional(:package) => %{
            required(:name) => String.t(),
            optional(:requirement) => String.t(),
            optional(:version) => String.t()
          },
          # "argus_only", "toolchain" or "warm_nerves" (`NccWorker.RunScope`).
          optional(:mode) => String.t(),
          # For "warm_nerves": `%{"name", "version"}` pairs to warm, string-keyed
          # (`NccWorker.WarmNerves.plan/2`); `[]` warms what the template resolves.
          optional(:nerves_packages) => [%{String.t() => String.t()}],
          # TCP targets to probe before any `mix` runs (`NccWorker.EgressProbe`),
          # string-keyed `%{"address", "port"}`; only `Portal.EgressCheck` sends it.
          optional(:egress_probe) => [%{String.t() => String.t() | pos_integer()}],
          optional(:systems_override) => %{String.t() => String.t()},
          optional(:systems_filter) => [String.t()],
          # The toolchain a "toolchain" run was queued for. Informational: the
          # worker records what it actually runs on, and echoes this back as
          # `requested_toolchain`.
          optional(:toolchain) => %{
            optional(:elixir) => String.t(),
            optional(:otp) => String.t()
          },
          # For "toolchain": "include" (the default) adds the optional
          # dependencies before the compile, "exclude" builds the package
          # without them.
          optional(:optional_deps) => String.t(),
          # For "toolchain": a `Compatibility.ConfigVariants` name; its overlay
          # is written as `config/config.exs` before the compile
          # (`NccWorker.ConfigOverlay`). Absent is `default`, no overlay.
          optional(:config_variant) => String.t(),
          optional(:argus) => %{
            optional(:analyses) => [String.t()],
            optional(:scope) => String.t(),
            optional(:timeout_seconds) => integer()
          },
          optional(:paths) => %{
            optional(:work_dir) => String.t(),
            optional(:output_dir) => String.t()
          },
          # Set by `run/1`, not by NCC_INPUT: monotonic seconds at the start.
          optional(:started_at) => integer(),
          optional(:limits) => %{
            optional(:per_system_timeout_sec) => integer(),
            optional(:log_tail_bytes) => integer()
          }
        }

  # One stored build of the package under test, for the host to recompute the
  # key from (`dep`, `dep_lock`, `target`, `elixir`, `otp`, `closure`) before
  # trusting and promoting it. See `NccWorker.BuildCache.store/2`.
  @type cache_candidate :: %{
          String.t() => String.t() | [%{String.t() => String.t()}]
        }

  # A "toolchain" run's verdict (`toolchain_build/5`): one prod host compile,
  # traced (`NccWorker.HostTrace`), in a plain `mix new` project on a toolchain image, judged by
  # `NccWorker.BuildSelection.portable?/4` AND the compile-time trace
  # (`NccWorker.Portability`, P1: it only adds refusals). `reason` is the
  # combined skip reason for "skipped" (`combine/2`) and what failed for
  # "error", nil for "pass". `deps_lock`,
  # `package_checksum` and `compile_env` describe the build ("pass" and
  # "skipped"); `file_manifest` lists the package's own files under
  # `_build/host/lib/<pkg>` for "pass" only, entries shaped like a beam scan's
  # `footprint.file_manifest`, and those files are archived by SHA256.
  @type toolchain_build :: %{
          status: String.t(),
          reason: String.t() | nil,
          elixir: String.t(),
          otp: String.t(),
          deps_lock: %{String.t() => %{String.t() => String.t()}} | nil,
          package_checksum: String.t() | nil,
          compile_env: [map()] | nil,
          # 1 when `compile_env` also lists the compile-time config reads the
          # trace observed across the package's closure (`ConfigReads`, R5);
          # nil when it is the `.app`'s own list alone.
          compile_env_rule: 1 | nil,
          # The config variant the build was made in, echoed for the portal
          # to check against the job.
          config_variant: String.t(),
          # The verdict's rule: 1 is `BuildSelection.portable?/4` AND the
          # compile-time trace's refusals (P1); nil for an "error" build.
          portability_rule: 1 | nil,
          # What `portable?/4` alone said: its skip reason, nil when it passed
          # or when the traced compile did not finish (it then judges nothing).
          rule1_reason: String.t() | nil,
          # What the trace observed (`NccWorker.Portability`): "trace_stats"
          # (with "judge_compile", "finished" | "not_finished" | "not_run",
          # "transient", true when a could-not-judge says nothing about the
          # package and the portal stores it as an error to retry,
          # "report_over_budget", the phase times "wall_ms", "compile_ms",
          # "report_ms" and "judge_ms", "tracer_error", why the traced
          # compile did not finish (nil when it did), "trace_mode", "host" | "judge", "host_build",
          # "traced" | "untraced" | "none", which build the host status is
          # (`NccWorker.HostTrace`), and "host_compile_sec": in a toolchain
          # run the traced host compile's own time, its `deps.get` and any
          # untraced fallback included),
          # "config_reads",
          # "elixir_version", "native_calls", "mix_exs_allowed",
          # "build_root_source_path", "refusals", "taint", "native_libs",
          # "nif_check", "problems"; nil for an "error" build.
          compile_observations: map() | nil,
          file_manifest:
            %{
              String.t() => [
                %{String.t() => String.t() | non_neg_integer()}
              ]
            }
            | nil
        }

  @type result :: %{
          # "full", "targets", "argus_only", "toolchain" or "warm_nerves".
          optional(:scope) => String.t(),
          # Only for a "toolchain" run, whose `systems` is `%{}`: no firmware,
          # no argus (`argus.status` "skipped"), no Nerves systems.
          optional(:toolchain_build) => toolchain_build(),
          # Only for a run whose selection was `pure_elixir`: whether its host
          # files were published (P0's OS check AND the compile-time trace,
          # `NccWorker.Portability`). "skipped" publishes no `pure_elixir`
          # files and changes no status; `reason` is the OS check's
          # ("OS-specific (<file>: <needle>)"), the trace's refusal, or
          # "portability could not be judged" (the tracer failed, was killed,
          # overflowed or could not start). `compile_observations` as for a
          # toolchain build, nil when the OS check failed and the trace never
          # ran.
          optional(:host_portability) => %{
            status: String.t(),
            reason: String.t() | nil,
            portability_rule: 1,
            compile_observations: map() | nil
          },
          # `NCC_INPUT.toolchain` echoed back, when present.
          optional(:requested_toolchain) => map(),
          # A toolchain run's `NCC_INPUT.optional_deps` ("include" or
          # "exclude") echoed back, when present: the portal checks it
          # against the variant it queued the build as.
          optional(:requested_optional_deps) => String.t(),
          # The package's optional dependencies the generated project did not
          # resolve on its own (`NccWorker.DepsLock.unresolved_optional_deps/2`),
          # and what the best-effort second pass did with them. Statuses and
          # the classification come from the build without them; only the
          # published files are rebuilt with `added` loadable: a pure-Elixir
          # package's host build, and then the run's `deps_lock` names them,
          # or a firmware package's passing targets
          # (`NccWorker.OptionalDepsTargets`), and then each kept system's own
          # `deps_lock` does while the run's stays the status build's.
          # For a firmware run `added` were kept on at least one target and
          # `dropped` on every target that tried; each passing system carries
          # its own `optional_deps`. `reason` says why they were dropped
          # (for a firmware run, the first target's reason):
          # "deps_get_failed", "lock_policy_violation", "host_compile_failed",
          # "target_compile_failed", "timeout", "stale_build_not_removed",
          # "deps_lock_unreadable", "mix_exs_edit_failed",
          # "run_budget_exhausted" or "no_passing_target", `nil` when nothing
          # was dropped. A toolchain run adds them before its only compile
          # instead, and is absent when the compile without them fails too
          # (`toolchain_compile/5`); one asked for `optional_deps: "exclude"`
          # never tries: everything empty and "not_requested". Absent for
          # argus-only runs.
          # `skipped` were never tried: dev tooling and alternatives on
          # `Compatibility.OptionalDeps.never_added/0`.
          optional(:optional_deps) => %{
            added: [String.t()],
            dropped: [String.t()],
            skipped: [String.t()],
            reason: String.t() | nil
          },
          # The package's transitive dependency closure as locked for this
          # build, itself excluded, keyed by name. For a firmware run, the
          # lock of the status build, read before the per-target optional
          # pass. Absent when the lock could not be read and for argus-only
          # runs, which build no files.
          optional(:deps_lock) => %{
            String.t() => %{required(String.t()) => String.t()}
          },
          # The package's own outer Hex checksum from the project's mix.lock.
          # Absent when the lock could not be read and for argus-only runs.
          optional(:package_checksum) => String.t(),
          # A build's Nerves cache misses (artifacts Nerves had to extract into
          # the run's farm) and its locked nerves_system_*/nerves_toolchain_*
          # packages, string-keyed `%{"name", "version"}` pairs, for the host to
          # warm (`NccWorker.NervesCache.report/2`). Absent when both are empty,
          # for toolchain runs and under NCC_NERVES_CACHE_RW=1.
          optional(:nerves_cache) => %{
            misses: [%{String.t() => String.t()}],
            lock: [%{String.t() => String.t()}]
          },
          # Only for a "warm_nerves" run, whose `package` is nil and `systems`
          # `%{}` (`NccWorker.WarmNerves`).
          optional(:warm) => NccWorker.WarmNerves.warm(),
          # The outcome per `NCC_INPUT.egress_probe` target, when it had any.
          optional(:egress_probe) => [NccWorker.EgressProbe.outcome()],
          # How the process sweep went: "ok", "skipped" or "tainted", set by
          # the CLI (`NccWorker.ProcessSweep.enforce_and_report/2`) after
          # `run/1` returns. Informational: the container's own account, for
          # monitoring; the portal does not trust it.
          optional(:process_sweep) => String.t(),
          run_id: String.t(),
          # nil for a "warm_nerves" run.
          package:
            %{
              name: String.t(),
              version: String.t(),
              description: String.t(),
              dependencies:
                list(%{
                  name: String.t(),
                  requirement: String.t(),
                  optional: boolean(),
                  runtime: boolean(),
                  app: String.t() | nil
                }),
              footprint: %{
                file_count: integer(),
                total_bytes: integer()
              }
            }
            | nil,
          image: %{
            name: String.t(),
            digest: String.t()
          },
          toolchain: %{
            elixir: String.t(),
            erlang: String.t(),
            mix: String.t(),
            # "absent" for a toolchain run, whose image has no nerves_bootstrap.
            nerves_bootstrap: String.t() | nil
          },
          systems: %{
            String.t() => %{
              # Present only for a system that ran a build cache store: a
              # passing `build_system/4` or host compile (a failed one stores
              # nothing, so its list is empty). `JsonWriter`
              # concatenates every system's list, dedupes it by `"key"`, and
              # writes it to result.json as `cache: %{candidates: [candidate]}`
              # -- present there only when non-empty, rather than nested under
              # each system.
              optional(:cache_candidates) => [cache_candidate()],
              # Only on a firmware system that kept the optional dependencies
              # in the per-target pass (`NccWorker.OptionalDepsTargets`): the
              # closure its published files were built against, shaped like
              # the run's `deps_lock`, which applies to every other system.
              optional(:deps_lock) => %{String.t() => %{String.t() => String.t()}},
              # Only on a firmware system that was passing when the per-target
              # pass ran: what it did on this target. `reason` as for the
              # run's `optional_deps`, `nil` when kept.
              optional(:optional_deps) => %{
                added: [String.t()],
                dropped: [String.t()],
                reason: String.t() | nil
              },
              # 1 on a `pure_elixir` result published with the trace's
              # config reads in `compile_env` (R5), nil on one that is not;
              # absent on firmware results and from `result.json` when nil.
              optional(:compile_env_rule) => 1 | nil,
              status: Compatibility.Types.status(),
              duration_sec: float(),
              phase_timings: map() | nil,
              firmware_size_bytes: integer() | nil,
              log_tail: String.t(),
              system_version: String.t() | nil,
              compile_env: list(map()) | nil,
              beam_scan: map() | nil,
              dependency_scans: map() | nil,
              error: String.t() | nil
            }
          },
          finished_at: String.t(),
          argus: NccWorker.Argus.result()
        }

  @default_timeout_sec 600
  @default_log_tail_bytes 4096
  @max_build_concurrency 4

  # How many target-independent dependencies must be missing from the build
  # cache before one target builds alone to seed it. See build_all_systems/6.
  @seed_min_missing_shared 10

  # The generated wrapper application, from `Project.new_project/2`. It is not a
  # dependency of anything and is rewritten for every package, so caching its
  # build would be both wrong and pointless.
  @wrapper_app "nerves_compatibility_test"

  @doc """
  Runs the worker evaluation for a single package.

  ## Parameters
    - input: Map containing run configuration (see @type input)

  ## Returns
    - {:ok, result} - Evaluation completed successfully
    - {:error, reason} - Worker failed (internal error or policy violation)
  """
  @spec run(input()) :: {:ok, result()} | {:error, term()}
  def run(input) do
    # The optional pass's 75-minute rule counts from here
    # (`NccWorker.OptionalDepsTargets`).
    started_at = System.monotonic_time(:second)
    scope = RunScope.from_input(input)

    with :ok <- validate_input(input),
         {:ok, paths} <- setup_paths(input),
         # Before any `mix`, so the probe sees the network a build's
         # `deps.get` would (isolation spec, section 3). Advisory.
         egress = EgressProbe.run(input[:egress_probe]),
         {:ok, nerves} <- prepare_nerves_cache(scope, input, paths),
         {:ok, hex} <- prepare_hex_cache(scope, paths),
         {:ok, toolchain} <- detect_toolchain(scope) do
      scope
      |> run_scope(Map.put(input, :started_at, started_at), paths, toolchain, nerves)
      |> put_hex_cache(hex, paths)
      |> EgressProbe.put_result(egress)
    end
  end

  # Before any `mix` runs, like the Nerves cache: `/hex-cache` is read-only,
  # so every `mix` this run starts must inherit a writable `HEX_HOME`
  # (`NccWorker.HexCache`). A warm run sets its own empty one
  # (`NccWorker.WarmNerves`) and reports nothing.
  defp prepare_hex_cache(:warm_nerves, _paths), do: {:ok, nil}

  defp prepare_hex_cache(_scope, paths) do
    with {:ok, layout} <- HexCache.prepare(work_dir: paths.work_dir) do
      :ok = HexCache.export_env(layout)
      {:ok, layout}
    end
  end

  # Every scope's project is `<work_dir>/proj`, the toolchain run's included.
  defp put_hex_cache({:ok, result}, layout, paths) when is_map(layout),
    do: {:ok, HexCache.put_report(result, layout, Path.join(paths.work_dir, "proj"))}

  defp put_hex_cache(other, _layout, _paths), do: other

  defp run_scope(:toolchain, input, paths, toolchain, _nerves),
    do: toolchain_run(input, paths, toolchain)

  defp run_scope(:warm_nerves, input, paths, toolchain, nerves),
    do: WarmNerves.run(input, paths, toolchain, nerves)

  defp run_scope(_scope, input, paths, toolchain, nerves),
    do: input |> full_run(paths, toolchain) |> put_nerves_cache(nerves, paths)

  # Before any `mix` runs, `detect_toolchain/1`'s included: every later
  # invocation is a child of this process and inherits both variables, so
  # Nerves never falls back to `~/.nerves` (`NccWorker.NervesCache`). Every
  # mode sets them; only a full, targets or argus-only run reports.
  defp prepare_nerves_cache(scope, input, paths) do
    kind = if scope == :warm_nerves, do: :warm, else: :build

    with {:ok, layout} <-
           NervesCache.prepare(kind, work_dir: paths.work_dir, run_id: input.run_id) do
      :ok = NervesCache.export_env(layout)
      {:ok, layout}
    end
  end

  # At the end of the run, not after `deps.get`: Nerves 2 resolves artifacts
  # when the nerves_bootstrap compile hook runs, which in a build is
  # `mix firmware`.
  defp put_nerves_cache({:ok, result}, layout, paths),
    do: {:ok, NervesCache.put_report(result, layout, Path.join(paths.work_dir, "proj"))}

  defp put_nerves_cache(other, _layout, _paths), do: other

  defp full_run(input, paths, toolchain) do
    {description, github_url, release_info, retired_info, metadata_version, build_tools} =
      fetch_metadata(input)

    context = %{
      input: input,
      paths: paths,
      toolchain: toolchain,
      timeout: get_in(input, [:limits, :per_system_timeout_sec]) || @default_timeout_sec,
      log_tail_bytes: get_in(input, [:limits, :log_tail_bytes]) || @default_log_tail_bytes,
      description: description,
      github_url: github_url,
      release_info: release_info,
      retired_info: retired_info,
      package_version_hint: metadata_version || input.package[:version],
      build_tools: build_tools
    }

    if gleam_build_tool?(build_tools),
      do: skipped_gleam(context),
      else: prepare_project(context)
  end

  defp fetch_metadata(input) do
    case HexMetadata.fetch(input.package.name, input.package[:version]) do
      {:ok,
       %{
         description: desc,
         github_url: gh,
         dependencies: release,
         retired: retired,
         release_version: release_version,
         build_tools: tools
       }} ->
        {desc, gh, release, retired, release_version, tools}

      {:error, reason} ->
        IO.puts(:stderr, "Warning: Failed to fetch Hex metadata: #{inspect(reason)}")
        {"Package #{input.package.name}", nil, nil, nil, nil, []}
    end
  end

  defp skipped_gleam(%{
         input: input,
         paths: paths,
         toolchain: toolchain,
         log_tail_bytes: log_tail_bytes,
         description: description,
         github_url: github_url,
         release_info: release_info,
         package_version_hint: package_version_hint,
         build_tools: build_tools
       }) do
    skip_reason = gleam_skip_reason(build_tools)

    dependencies =
      case release_info do
        release when is_map(release) -> HexMetadata.parse_dependencies(release, [])
        _ -> []
      end

    beam_scan = build_skipped_beam_scan(build_tools)

    system_results =
      build_forced_skip_system(paths.output_dir, skip_reason, log_tail_bytes, beam_scan)

    footprint = empty_footprint()

    result = %{
      run_id: input.run_id,
      package: %{
        name: input.package.name,
        version: package_version_hint || "unknown",
        description: description,
        github_url: github_url,
        dependencies: dependencies,
        footprint: footprint
      },
      image: input.image,
      toolchain: toolchain,
      systems: system_results,
      argus: Argus.skipped(),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, result}
  end

  defp skipped_retired(%{
         input: input,
         paths: paths,
         toolchain: toolchain,
         log_tail_bytes: log_tail_bytes,
         description: description,
         github_url: github_url,
         retired_info: retired_info,
         package_version_hint: package_version_hint
       }) do
    reason = format_retired_reason(retired_info)

    system_results =
      build_forced_skip_system(paths.output_dir, reason, log_tail_bytes, nil)

    footprint = empty_footprint()

    result = %{
      run_id: input.run_id,
      package: %{
        name: input.package.name,
        version: package_version_hint || "unknown",
        description: description,
        github_url: github_url,
        dependencies: [],
        footprint: footprint
      },
      image: input.image,
      toolchain: toolchain,
      systems: system_results,
      argus: Argus.skipped(),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, result}
  end

  defp prepare_project(%{input: input, paths: paths, retired_info: retired_info} = context) do
    systems = Systems.select(input[:systems_filter])

    with {:ok, project_dir} <-
           Project.create(paths.work_dir, input[:systems_override], Systems.targets(systems)),
         {:ok, _} <- add_package(project_dir, input, systems, context),
         :ok <- LockPolicy.validate(project_dir) do
      if retired_info do
        skipped_retired(context)
      else
        context |> Map.merge(%{project_dir: project_dir, systems: systems}) |> evaluate_project()
      end
    end
  end

  # Wraps `Project.add_package/3` so a `deps.get` failure for the package
  # under test -- not a Nerves system or toolchain dep, those are
  # `Project.create/3`'s problem -- gets classified before it can reach the
  # `with` above as a bare `{:error, _}`. `deps_get_verdict/3` turns a
  # deterministic failure into `{:ok, result}` with every `with` clause below
  # (LockPolicy, `evaluate_project/1`) short-circuited away, same effect as
  # if a later verdict had already been reached; a transient one, or any
  # other `add_package` error, passes through unchanged for the `with` to
  # report as today (exit 10).
  defp add_package(project_dir, input, systems, context) do
    case Project.add_package(project_dir, input.package, host_env(project_dir)) do
      {:error, {:deps_get_failed, output}} -> deps_get_verdict(context, systems, output)
      other -> other
    end
  end

  @doc false
  # Classifies a `deps.get` failure for the package under test
  # (`NccWorker.DepsGetClassifier`). Transient stays `{:error, {:deps_get_failed,
  # output}}` so the caller's `with` reports it like any other internal
  # failure (exit 10, retried). Deterministic becomes a normal verdict: every
  # system this run would have built (respecting `systems_filter`) is
  # recorded `status: "error"`, `error: "deps_get_failed"`, so the portal
  # ingests it once instead of retrying something that will never change.
  @spec deps_get_verdict(map(), [Systems.t()], String.t()) ::
          {:ok, result()} | {:error, {:deps_get_failed, String.t()}}
  def deps_get_verdict(context, systems, output) do
    case DepsGetClassifier.classify(output) do
      :transient -> {:error, {:deps_get_failed, output}}
      :deterministic -> {:ok, deps_get_failure_result(context, systems, output)}
    end
  end

  defp deps_get_failure_result(
         %{
           input: input,
           paths: paths,
           toolchain: toolchain,
           log_tail_bytes: log_tail_bytes,
           description: description,
           github_url: github_url,
           package_version_hint: package_version_hint
         },
         systems,
         output
       ) do
    scope = RunScope.from_input(input)

    {system_results, argus} =
      deps_get_outcome(scope, systems, paths.output_dir, log_tail_bytes, output)

    %{
      run_id: input.run_id,
      package: %{
        name: input.package.name,
        version: package_version_hint || "unknown",
        description: description,
        github_url: github_url,
        dependencies: [],
        footprint: empty_footprint()
      },
      image: input.image,
      toolchain: toolchain,
      systems: system_results,
      argus: argus,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scope: RunScope.to_string(scope)
    }
  end

  # An argus_only run only ever follows a same-version full run
  # (`Portal.Workers.Build.scope_args/3` picks this mode only when
  # `latest_version_tested(package)` already equals the requested version).
  # A deterministic verdict here must not name a single system: ingestion's
  # carry-forward (`Portal.Catalog.Ingestion.carry_candidates/4`) only
  # copies systems the new run did NOT report, so naming them `status:
  # :error` would overwrite that previous run's real statuses -- flipping a
  # passing package to error from what is supposed to be an advisory sweep.
  # No systems also means no per-system logs. Argus itself is marked
  # skipped with a reason, the same vocabulary every other skip uses.
  defp deps_get_outcome(:argus_only, _systems, _output_dir, _log_tail_bytes, _output),
    do: {%{}, %{Argus.skipped() | reason: "deps_get_failed"}}

  defp deps_get_outcome(_scope, systems, output_dir, log_tail_bytes, output),
    do: {deps_get_error_systems(systems, output_dir, log_tail_bytes, output), Argus.skipped()}

  defp deps_get_error_systems(systems, output_dir, log_tail_bytes, output) do
    log_tail = truncate_tail(output, log_tail_bytes)

    Map.new(systems, fn system ->
      write_deps_get_log(output_dir, system.name, output)

      {system.name,
       %{
         status: :error,
         duration_sec: 0.0,
         firmware_size_bytes: nil,
         log_tail: log_tail,
         system_version: nil,
         beam_scan: nil,
         dependency_scans: nil,
         error: "deps_get_failed"
       }}
    end)
  end

  # Same fixed `logs/<system name>.log` convention `build_all_systems/6` and
  # `compile_host/4` use, so `Portal.Catalog.Ingestion.stage_logs/2` finds it.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_deps_get_log(output_dir, system_name, output) do
    log_file = Path.join([output_dir, "logs", "#{system_name}.log"])
    :ok = File.write!(log_file, output)
  end

  defp evaluate_project(%{
         input: input,
         paths: paths,
         toolchain: toolchain,
         project_dir: project_dir,
         systems: systems,
         timeout: timeout,
         log_tail_bytes: log_tail_bytes,
         description: description,
         github_url: github_url,
         release_info: release_info,
         package_version_hint: package_version_hint
       }) do
    # Source-dir snapshot: taken after `mix deps.get` populated
    # `deps/<pkg>/` but before any firmware or host compile runs.
    # Compared with a second snapshot taken after all builds so we
    # can flag packages that write artifacts back into source (bad
    # news when switching MIX_TARGET between builds).
    pkg_source_dir = Path.join([project_dir, "deps", input.package.name])

    {:ok, source_before} = NccWorker.SourceScanner.snapshot(pkg_source_dir)

    # Before the host compile, as in a toolchain run: the releases a
    # `pure_elixir` build is judged against (`judge_releases/2`). This is the
    # earliest point there is: the `deps.get` that wrote the lock is the one
    # `Project.add_package/3` ran.
    first_releases = Portability.lock_snapshot(project_dir)

    host_result =
      compile_host(project_dir, paths.output_dir, log_tail_bytes, input.package.name)

    scope = RunScope.from_input(input)

    # Classified on the closure without the package's optional dependencies,
    # like the status: code the package never needs must not send it to
    # firmware builds.
    selection =
      BuildSelection.select(
        project_dir,
        input.package.name,
        description,
        host_result,
        host_env(project_dir)
      )

    # Read before the optional pass below can add its optional dependencies
    # to the package's `.app`: the package metadata describes the package as
    # it was checked.
    runtime_apps =
      runtime_applications(project_dir, input)

    with {:ok, optional_deps} <-
           resolve_optional_deps(scope, selection, project_dir, input.package.name, paths) do
      # The lock snapshot matching the build the traced judge compile
      # judges; it is not part of `result.json`.
      {releases, optional_deps} = judge_releases(first_releases, optional_deps)

      context = %{
        input: input,
        paths: paths,
        project_dir: project_dir,
        systems: systems,
        timeout: timeout,
        log_tail_bytes: log_tail_bytes,
        description: description,
        release_info: release_info,
        package_version_hint: package_version_hint,
        host_result: host_result,
        scope: scope,
        selection: selection,
        runtime_apps: runtime_apps,
        source_before: source_before,
        pkg_source_dir: pkg_source_dir,
        releases: releases
      }

      finish_project(context, toolchain, github_url, optional_deps)
    end
  end

  defp finish_project(
         %{
           input: input,
           paths: paths,
           project_dir: project_dir,
           systems: systems,
           timeout: timeout,
           log_tail_bytes: log_tail_bytes,
           host_result: host_result,
           scope: scope,
           selection: selection,
           releases: releases
         } = context,
         toolchain,
         github_url,
         optional_deps
       ) do
    portability =
      full_run_portability(project_dir, paths,
        releases: releases,
        run_started_at: input[:started_at],
        rebuild_timeout_sec: timeout,
        host_compile_sec: host_result[:duration_sec]
      )

    build = %{
      firmware: fn ->
        build_all_systems(
          project_dir,
          systems,
          paths.output_dir,
          timeout,
          log_tail_bytes,
          input.package.name,
          host_result
        )
      end,
      pure_elixir: fn -> pure_elixir_result(project_dir, input.package.name, portability) end
    }

    target_pass = %{
      project_dir: project_dir,
      package: input.package.name,
      systems: systems,
      paths: paths,
      timeout: timeout,
      started_at: Map.get(input, :started_at, System.monotonic_time(:second))
    }

    with {:ok, system_results, optional_deps, run_lock} <-
           build_systems(scope, selection, build, target_pass, optional_deps) do
      finish_result(
        Map.put(system_results, "host", host_result),
        Map.merge(context, %{
          toolchain: toolchain,
          github_url: github_url,
          optional_deps: optional_deps,
          run_lock: run_lock
        })
      )
    end
  end

  defp finish_result(system_results, %{
         input: input,
         project_dir: project_dir,
         systems: systems,
         description: description,
         release_info: release_info,
         package_version_hint: package_version_hint,
         host_result: host_result,
         scope: scope,
         selection: selection,
         runtime_apps: runtime_apps,
         source_before: source_before,
         pkg_source_dir: pkg_source_dir,
         toolchain: toolchain,
         github_url: github_url,
         optional_deps: optional_deps,
         run_lock: run_lock
       }) do
    {:ok, source_after} = NccWorker.SourceScanner.snapshot(pkg_source_dir)
    source_changes = NccWorker.SourceScanner.diff(source_before, source_after)

    # Advisory: argus reads the host beams once for every system. Its result
    # never feeds a system status.
    argus =
      Argus.run(
        project_dir,
        input.package.name,
        RunScope.argus_config(input[:argus], scope),
        selection,
        host_result
      )

    package_version =
      case get_package_version(project_dir, input.package) do
        "unknown" when is_binary(package_version_hint) ->
          package_version_hint

        version ->
          version
      end

    {final_description, dependencies} =
      case release_info do
        release when is_map(release) ->
          deps = HexMetadata.parse_dependencies(release, runtime_apps)
          {description, deps}

        _ ->
          {description, []}
      end

    footprint = footprint_for(scope, selection, project_dir, input.package.name, systems)

    native_components =
      (NccWorker.NativeLang.detect(project_dir, input.package.name) || %{})
      |> Map.put(:compatibility_basis, Atom.to_string(selection))

    result = %{
      run_id: input.run_id,
      package: %{
        name: input.package.name,
        version: package_version,
        description: final_description,
        github_url: github_url,
        dependencies: dependencies,
        native_components: native_components,
        source_changes: source_changes,
        footprint: footprint
      },
      image: input.image,
      toolchain: toolchain,
      systems: system_results,
      argus: argus,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scope: RunScope.to_string(scope)
    }

    {:ok,
     result
     |> put_optional_deps(optional_deps)
     |> put_deps_lock(scope, run_lock, project_dir, input.package.name)
     |> put_host_portability(system_results)}
  end

  @doc false
  # `host_portability` only for a run whose selection was `pure_elixir`: it
  # says whether that system's files were published. Public for tests.
  @spec put_host_portability(map(), map()) :: map()
  def put_host_portability(result, %{"pure_elixir" => %{host_portability: hp}}),
    do: Map.put(result, :host_portability, hp)

  def put_host_portability(result, _systems), do: result

  defp put_optional_deps(result, nil), do: result

  defp put_optional_deps(result, optional_deps),
    do: Map.put(result, :optional_deps, optional_deps)

  # The package's optional dependencies, as a best-effort pass after its
  # status is settled. A real application almost always has them in its lock
  # (decimal next to jason), and the package compiles differently with them
  # loadable, so files built without them match no such application in the
  # precompiled API (see `NccWorker.DepsLock.unresolved_optional_deps/2`).
  #
  # A pure-Elixir package gets the pass here: its one set of published files
  # is the host build, which this recompiles. A firmware package's files come
  # from every target's build, so for it this only decides what to add
  # (`{:per_target, deps, skipped}`) and `NccWorker.OptionalDepsTargets`
  # recompiles each passing target after the firmware builds. Nothing here
  # touches a status, the host result or the classification: whatever goes
  # wrong, the project is put back and the package rebuilt without them.
  #
  # `nil` (no `optional_deps` key) for an argus-only run, which publishes
  # nothing.
  defp resolve_optional_deps(:argus_only, _selection, _project_dir, _package, _paths),
    do: {:ok, nil}

  defp resolve_optional_deps(_scope, selection, project_dir, package_name, paths) do
    {deps, skipped} =
      project_dir
      |> DepsLock.unresolved_optional_deps(package_name)
      |> Project.optional_deps_to_add()

    if skipped != [] do
      log_host(
        paths,
        "Not adding optional dependencies #{Enum.join(skipped, ", ")}: " <>
          "tooling or alternatives most applications do not lock"
      )
    end

    case optional_deps_pass(deps, selection, project_dir, package_name, paths) do
      {:ok, {:per_target, deps}} -> {:ok, {:per_target, deps, skipped}}
      {:ok, info} -> {:ok, Map.put(info, :skipped, skipped)}
      error -> error
    end
  end

  # A firmware package gets them per target after its firmware builds
  # (`NccWorker.OptionalDepsTargets`), so nothing is added here.
  defp optional_deps_pass(deps, :firmware, _project_dir, _package_name, _paths),
    do: {:ok, {:per_target, deps}}

  defp optional_deps_pass([], _selection, _project_dir, _package_name, _paths),
    do: {:ok, optional_deps_info([], [], nil)}

  defp optional_deps_pass(deps, _selection, project_dir, package_name, paths),
    do: add_optional_deps(project_dir, package_name, deps, paths)

  defp add_optional_deps(project_dir, package_name, deps, paths) do
    names = Enum.map(deps, & &1.app)
    env = host_env(project_dir)

    log_host(
      paths,
      "Adding optional dependencies: " <>
        Enum.map_join(deps, ", ", &"#{&1.app} #{&1.requirement}")
    )

    with {:ok, snapshot} <- Project.snapshot(project_dir) do
      case Project.add_optional_deps(project_dir, package_name, deps, env) do
        {:ok, []} ->
          {:ok, optional_deps_info([], [], nil)}

        {:ok, added} ->
          build_with_optional_deps(project_dir, package_name, paths, snapshot, added)

        {:error, {:restore_failed, _reason, _cause}} = error ->
          error

        # Restored already, but the package's build may be gone with it:
        # rebuilt without them, as on every other way out.
        {:error, reason} ->
          drop_optional_deps(project_dir, package_name, paths, snapshot, names, %{
            why: drop_why(reason),
            detail: reason,
            reason: drop_reason(reason)
          })
      end
    end
  end

  defp build_with_optional_deps(project_dir, package_name, paths, snapshot, added) do
    with {:policy, :ok} <- {:policy, LockPolicy.validate(project_dir)},
         # Right after the `deps.get` that fetched them and before the
         # compile that builds them: the releases the build with them is
         # judged against (`judge_releases/2`), its own optional deps included.
         releases = Portability.lock_snapshot(project_dir),
         {:compile, %{status: :pass}} <-
           {:compile, compile_host(project_dir, paths.output_dir, 0, package_name)} do
      {:ok, Map.put(optional_deps_info(added, [], nil), :lock_snapshot, releases)}
    else
      {:policy, {:error, reason}} ->
        drop_optional_deps(project_dir, package_name, paths, snapshot, added, %{
          why: "they bring in a dependency the lock policy rejects",
          detail: reason,
          reason: "lock_policy_violation"
        })

      {:compile, host} ->
        drop_optional_deps(project_dir, package_name, paths, snapshot, added, %{
          why: "the host compile failed with them",
          detail: host[:error],
          reason: "host_compile_failed"
        })
    end
  end

  # The package was built and classified without them already, so the same
  # build again only fails for a reason that has nothing to do with the
  # package; it is a retryable worker error rather than a published build of
  # files nobody checked.
  defp drop_optional_deps(project_dir, package_name, paths, snapshot, added, drop) do
    log_host(paths, drop_warning(added, drop.why, drop.detail))

    with :ok <- Project.drop_optional_deps(snapshot, package_name, host_env(project_dir)),
         %{status: :pass} <- compile_host(project_dir, paths.output_dir, 0, package_name) do
      {:ok, optional_deps_info([], added, drop.reason)}
    else
      {:error, reason} -> {:error, {:optional_deps_revert_failed, reason}}
      host -> {:error, {:rebuild_without_optional_deps_failed, host[:error]}}
    end
  end

  defp optional_deps_info(added, dropped, reason),
    do: %{added: added, dropped: dropped, reason: reason}

  defp drop_why({:deps_get_failed, _output}), do: "mix deps.get failed after adding them"
  defp drop_why(_reason), do: "they could not be added to the project"

  defp drop_reason({:deps_get_failed, _output}), do: "deps_get_failed"
  defp drop_reason({:rm_rf_failed, _reason, _path}), do: "stale_build_not_removed"
  defp drop_reason(_reason), do: "mix_exs_edit_failed"

  defp drop_warning(names, why, detail) do
    detail =
      case detail do
        {:deps_get_failed, output} -> LogTail.tail(output, 2000)
        nil -> ""
        text when is_binary(text) -> LogTail.tail(text, 2000)
        other -> inspect(other, limit: 20)
      end

    String.trim_trailing(
      "Warning: building without optional dependencies #{Enum.join(names, ", ")}: " <>
        "#{why}\n#{detail}"
    )
  end

  # Lines about the optional dependencies go into host.log as well as stderr,
  # so whoever reads that log sees what was added or dropped and why.
  # The log is the worker's own output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp log_host(paths, line) do
    IO.puts(:stderr, line)
    File.write(Path.join(paths.logs_dir, "host.log"), line <> "\n", [:append])
  end

  # The BEAMs a run publishes have their dependencies' macros expanded into
  # them, so they are only reusable against the exact tree they were built
  # with (`NccWorker.DepsLock`). An argus-only run publishes nothing, and a lock
  # that cannot be read leaves the key out rather than failing a finished build.
  #
  # A firmware run's lock was read before its per-target optional pass
  # (`run_lock`), so it is the lock the status build saw; any other run's is
  # read here.
  defp put_deps_lock(result, :argus_only, _run_lock, _project_dir, _package), do: result

  defp put_deps_lock(result, _scope, nil, project_dir, package) do
    run_lock = %{
      deps_lock: DepsLock.read(project_dir, package),
      package_checksum: DepsLock.package_checksum(project_dir, package)
    }

    put_deps_lock(result, :full, run_lock, project_dir, package)
  end

  defp put_deps_lock(result, _scope, run_lock, _project_dir, _package) do
    result
    |> put_present(:deps_lock, run_lock.deps_lock)
    |> put_present(:package_checksum, run_lock.package_checksum)
  end

  defp put_present(result, _key, nil), do: result
  defp put_present(result, key, value), do: Map.put(result, key, value)

  # An argus-only run compiles on the host for argus and stops there: the
  # targets it leaves out are carried over from the previous run at ingest.
  # Returns the systems, the run's `optional_deps` and, for a firmware run,
  # the lock read before its per-target pass (`nil` otherwise).
  defp build_systems(:argus_only, _selection, _build, _pass, optional_deps),
    do: {:ok, %{}, optional_deps, nil}

  defp build_systems(_scope, :pure_elixir, %{pure_elixir: pure}, _pass, optional_deps),
    do: {:ok, %{"pure_elixir" => pure.()}, optional_deps, nil}

  defp build_systems(_scope, :firmware, %{firmware: build}, pass, {:per_target, deps, skipped}) do
    {results, envs} = build.()

    targets =
      for system <- pass.systems, env = envs[system.name], env != nil do
        log_file = Path.join([pass.paths.output_dir, "logs", "#{system.name}.log"])
        {system.name, %{env: env, log_file: log_file}}
      end

    params = %{
      project_dir: pass.project_dir,
      package: pass.package,
      deps: deps,
      systems: results,
      targets: targets,
      timeout_sec: pass.timeout,
      concurrency: build_concurrency(),
      budget_sec: optional_pass_budget(),
      run_elapsed_sec: System.monotonic_time(:second) - pass.started_at
    }

    with {:ok, out} <- OptionalDepsTargets.run(params) do
      log_target_pass(pass.paths, out.systems)

      {:ok, out.systems, Map.put(out.optional_deps, :skipped, skipped),
       %{deps_lock: out.deps_lock, package_checksum: out.package_checksum}}
    end
  end

  # The per-target pass's wall-clock budget, NCC_OPTIONAL_PASS_BUDGET_SEC
  # (default 1200): with NCC_BUILD_CONCURRENCY=1 it could otherwise add
  # targets x per-system timeout to a run `Portal.Builder` kills at 2 h.
  defp optional_pass_budget do
    case Integer.parse(System.get_env("NCC_OPTIONAL_PASS_BUDGET_SEC", "")) do
      {n, ""} when n >= 0 -> n
      _ -> 1200
    end
  end

  # One line per target that tried, so host.log says where they were kept.
  defp log_target_pass(paths, systems) do
    for {name, %{optional_deps: info}} <- Enum.sort(systems) do
      line =
        case info do
          %{added: [_ | _] = added} ->
            "Optional dependencies #{Enum.join(added, ", ")} kept on #{name}"

          %{dropped: dropped, reason: reason} ->
            "Optional dependencies #{Enum.join(dropped, ", ")} dropped on #{name}: #{reason}"
        end

      log_host(paths, line)
    end

    :ok
  end

  # Nothing was built for the targets, so there is no firmware to measure.
  defp footprint_for(:argus_only, _selection, _project, _package, _systems),
    do: empty_footprint()

  defp footprint_for(_scope, selection, project, package, systems),
    do: package_footprint(selection, project, package, systems)

  # The host compile's BEAMs are the package's files on every target, so they
  # are scanned and archived like a firmware build's, and published as
  # precompiled files that fit any system. A client on any OS takes them, so
  # they are published only when the package's own source is OS-agnostic
  # (`BuildCache.os_agnostic?/1`, P0: a module body that reads `:os.type()`
  # bakes this Linux build host into the beams) AND the compile-time trace
  # passes (`portability`, `full_run_portability/3`, P1). The trace runs only
  # when the static check passed, and before the scan: it recompiles the
  # closure, so the files scanned and archived are the traced compile's own.
  # Otherwise the scan keeps no `file_manifest`, so nothing is archived or
  # published. The status, the assumed-compatible verdict and the log tail's
  # first sentence never change; `host_portability` says what was decided.
  # A published result lists the trace's config reads in its `compile_env`
  # and carries `compile_env_rule` 1 (`r5_compile_env/2`); a trace pass that
  # names no config reads at all is withheld as could-not-judge.
  @doc false
  @spec pure_elixir_result(String.t(), String.t(), (String.t() -> Portability.verdict())) ::
          map()
  def pure_elixir_result(project_dir, package_name, portability) do
    app_dir = Path.join([project_dir, "_build", "host", "lib", package_name])
    published = publication_gate(project_dir, package_name, portability)

    beam_scan =
      case BeamScan.analyze_app_dir(app_dir) do
        {:ok, scan} -> scan
        {:error, reason} -> %{"errors" => ["beam scan failed: #{inspect(reason)}"]}
      end

    app_env = AppFile.read_compile_env(Path.join([app_dir, "ebin", "#{package_name}.app"]))
    {gate, host_portability, verdict} = require_app_env(published, app_env)

    {compile_env, compile_env_rule} =
      if gate == :publish, do: r5_compile_env(app_env, verdict), else: {app_env, nil}

    {beam_scan, unpublished} = apply_gate(beam_scan, gate)

    %{
      status: :pass,
      duration_sec: 0.0,
      firmware_size_bytes: nil,
      log_tail:
        "Assumed compatible: host compilation passed and the resolved package and " <>
          "its dependencies contain only pure Elixir. No firmware targets were built." <>
          unpublished,
      compile_env: compile_env,
      compile_env_rule: compile_env_rule,
      beam_scan: beam_scan,
      error: nil,
      host_portability: host_portability
    }
  end

  defp publication_gate(project_dir, package_name, portability) do
    case BuildCache.os_agnostic?(Path.join([project_dir, "deps", package_name])) do
      :ok ->
        verdict = require_compile_env(portability.(package_name))
        {trace_gate(verdict), host_portability(verdict), verdict}

      {:error, {file, needle}} ->
        reason = "OS-specific (#{file}: #{needle})"
        verdict = %{status: :skip, reason: reason}
        {{:withhold, reason}, host_portability(verdict), verdict}
    end
  end

  # A `.app` that could not be read leaves `compile_env` nil, which no
  # client matches, so its files are withheld here rather than published
  # unmatched: a could-not-judge the package causes on every run.
  defp require_app_env({:publish, _host_portability, verdict}, nil) do
    verdict = cannot_judge(verdict, "compile_env unreadable: .app missing or unparsable")
    {trace_gate(verdict), host_portability(verdict), verdict}
  end

  defp require_app_env(published, _app_env), do: published

  defp trace_gate(%{status: :pass}), do: :publish
  defp trace_gate(%{reason: reason}) when is_binary(reason), do: {:withhold, reason}
  defp trace_gate(_verdict), do: {:withhold, PortabilityReasons.could_not_judge()}

  defp host_portability(%{status: :pass} = verdict),
    do: %{
      status: "pass",
      reason: nil,
      portability_rule: 1,
      compile_observations: verdict[:observations]
    }

  defp host_portability(verdict) do
    {:withhold, reason} = trace_gate(verdict)

    %{
      status: "skipped",
      reason: reason,
      portability_rule: 1,
      compile_observations: verdict[:observations]
    }
  end

  defp apply_gate(%{"footprint" => %{} = footprint} = scan, {:withhold, reason}),
    do:
      {Map.put(scan, "footprint", Map.delete(footprint, "file_manifest")),
       " Files not published: #{reason}."}

  defp apply_gate(scan, _gate), do: {scan, ""}

  @doc false
  # The full run's compile-time trace for `pure_elixir_result/3`: the same
  # traced judge compile a toolchain build gets (`run_portability/4`), with
  # the same `opts` (`releases:`, `run_started_at:`), and `rebuild_timeout_sec:`
  # (the per-system timeout), and `host_compile_sec:`, the host compile's
  # time, recorded next to the trace's as a toolchain build records it. A
  # traced compile that did not finish may have left `_build/host/lib`
  # half-written, and the full run still reads it: the
  # beam scan, `compile_env` and argus. So it is rebuilt untraced with
  # `mix compile` alone, bounded like the optional pass's compiles: no
  # `deps.get`, and no build cache store that could rewrite the candidates the
  # host compile reported. Nothing on this path can fail the run: a raise, a
  # throw or an exit in the trace is "portability could not be judged", one
  # in the rebuild is logged, and either way the status stands and nothing is
  # published. Public for tests, which inject `trace:` (`run_portability/4`'s
  # shape), `compile:` (`OptionalDepsTargets.bounded_compile/4`'s),
  # `timeout_ms:` and `cmd:` (`NccWorker.Tracer`'s judge compile command).
  @spec full_run_portability(String.t(), map(), keyword()) ::
          (String.t() -> Portability.verdict())
  def full_run_portability(project_dir, paths, opts) do
    trace = Keyword.get(opts, :trace, &run_portability/4)

    fn package_name ->
      verdict = guarded_trace(trace, project_dir, package_name, paths, opts)
      if unfinished?(verdict), do: guarded_rebuild(project_dir, paths, opts)
      put_host_time(verdict, Keyword.get(opts, :host_compile_sec))
    end
  end

  defp guarded_trace(trace, project_dir, package_name, paths, opts) do
    trace.(project_dir, package_name, paths, opts)
  rescue
    e -> trace_failed(Exception.message(e))
  catch
    kind, reason -> trace_failed("#{kind} #{inspect(reason, limit: 20)}")
  end

  # Nothing says whether the traced compile started, so it is treated as
  # one that did not finish, which says nothing about the package
  # (transient, `NccWorker.Portability.run/3`).
  defp trace_failed(why) do
    %{
      status: :skip,
      reason: PortabilityReasons.could_not_judge(),
      observations: %{
        "problems" => ["portability failed: " <> why],
        "trace_stats" => %{"judge_compile" => "not_finished", "transient" => true}
      }
    }
  end

  defp guarded_rebuild(project_dir, paths, opts) do
    rebuild_untraced(project_dir, paths, opts)
  rescue
    e -> rebuild_failed(paths, Exception.message(e))
  catch
    kind, reason -> rebuild_failed(paths, "#{kind} #{inspect(reason, limit: 20)}")
  end

  defp rebuild_failed(paths, why) do
    log_host(paths, "Warning: the rebuild failed: " <> why)
  rescue
    _ -> :ok
  end

  defp rebuild_untraced(project_dir, paths, opts) do
    case rebuild_timeout(opts) do
      :exhausted ->
        log_host(paths, "The traced compile did not finish; no time left to rebuild it")

      timeout_sec ->
        log_host(paths, "The traced compile did not finish; rebuilding without the trace")
        rebuild_compile(project_dir, paths, timeout_sec, opts)
    end
  end

  defp rebuild_compile(project_dir, paths, timeout_sec, opts) do
    compile = Keyword.get(opts, :compile, &OptionalDepsTargets.bounded_compile/4)
    log_file = Path.join([paths.output_dir, "logs", "host.log"])

    with :ok <- compile.(project_dir, host_env(project_dir), log_file, timeout_sec),
         :ok <- OptionalDepsTargets.reap_writers(Path.join([project_dir, "_build", "host"])) do
      :ok
    else
      error -> rebuild_failed(paths, inspect(error, limit: 20))
    end
  end

  # The per-system timeout, cut to what is left of the run as the judge
  # compile's is (`NccWorker.Tracer.timeout_sec/2`).
  defp rebuild_timeout(opts) do
    seconds = Keyword.get(opts, :rebuild_timeout_sec, @default_timeout_sec)

    elapsed =
      case Keyword.get(opts, :run_started_at) do
        nil -> nil
        started -> max(System.monotonic_time(:second) - started, 0)
      end

    NccWorker.Tracer.timeout_sec(seconds * 1000, elapsed)
  end

  # A toolchain run (`mode: "toolchain"`, `NccWorker.RunScope`) answers one
  # question: are the package's own beams, built by this image's Elixir and
  # OTP, the same on every OS and architecture? A plain `mix new` project
  # gets the package and, unless the input's `optional_deps` is "exclude",
  # its unresolved optional dependencies; then one host compile, traced
  # (`NccWorker.HostTrace`), whose files are judged and archived. No
  # firmware, no argus, no systems, no Hex metadata fetch, and no build
  # cache: the trace must see every closure dependency compiled, so nothing
  # is restored from the cache and nothing is stored for it.
  defp toolchain_run(input, paths, toolchain) do
    with {:ok, project_dir} <- Project.create_plain(paths.work_dir, @wrapper_app),
         {:ok, _} <- Project.add_package(project_dir, input.package, host_env(project_dir)),
         :ok <- LockPolicy.validate(project_dir) do
      toolchain_project(project_dir, input, paths, toolchain, [])
    end
  end

  @doc false
  # The toolchain run once its project has the package and passed the lock
  # policy: the compile (`toolchain_compile/5`) and the result. Public for
  # tests, whose `opts` reach `toolchain_compile/5`.
  @spec toolchain_project(String.t(), map(), map(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def toolchain_project(project_dir, input, paths, toolchain, opts) do
    package_name = input.package.name
    config_variant = input[:config_variant] || Compatibility.ConfigVariants.default()

    with :ok <- overlay(project_dir, config_variant) do
      toolchain_project(project_dir, input, paths, toolchain, opts, package_name, config_variant)
    end
  end

  # A variant whose overlay cannot be written is a worker failure (exit 10):
  # building it without the overlay would record it as the wrong variant.
  defp overlay(project_dir, config_variant) do
    case NccWorker.ConfigOverlay.write(project_dir, config_variant) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_overlay_failed, reason}}
    end
  end

  defp toolchain_project(project_dir, input, paths, toolchain, opts, package_name, config_variant) do
    log_tail_bytes = get_in(input, [:limits, :log_tail_bytes]) || @default_log_tail_bytes

    compile_opts =
      [
        # Right after `deps.get` and before any compile: an untraced build
        # step could rewrite the lock and a tarball together later.
        releases: Portability.lock_snapshot(project_dir),
        run_started_at: input[:started_at],
        log_tail_bytes: log_tail_bytes
      ] ++ opts

    with {:ok, compiled} <-
           toolchain_compile(
             project_dir,
             input[:optional_deps],
             package_name,
             paths,
             compile_opts
           ) do
      result =
        %{
          run_id: input.run_id,
          package: %{
            name: package_name,
            version: get_package_version(project_dir, input.package),
            dependencies: [],
            footprint: empty_footprint()
          },
          image: input.image,
          toolchain: toolchain,
          systems: %{},
          argus: Argus.skipped(),
          finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          scope: RunScope.to_string(:toolchain),
          toolchain_build:
            project_dir
            |> toolchain_build(package_name, compiled.host, toolchain, compiled.verdict)
            |> Map.put(:config_variant, config_variant)
        }
        |> put_optional_deps(compiled.optional_deps)
        |> put_deps_lock(:toolchain, nil, project_dir, package_name)
        |> put_requested_toolchain(input[:toolchain])
        |> put_requested_optional_deps(input[:optional_deps])

      {:ok, result}
    end
  end

  @doc false
  # The toolchain run's one compile (`NccWorker.HostTrace`). With "exclude"
  # nothing is added. Otherwise the package's unresolved optional
  # dependencies, read from the lock, are added before it, so the closure is
  # compiled once, with them, the way an application that locks them
  # compiles it. When they cannot be added, break the lock policy, or the
  # compile with them fails, the project is put back, `_build/host` is
  # removed and the compile runs without them; `optional_deps` says what was
  # dropped and why, and is nil when that compile fails too.
  #
  # A host compile that is a worker error (processes left running, a
  # `_build` that cannot be removed) or that raises, throws or exits is
  # `{:error, _}`, a retryable worker failure (exit 10): it says nothing
  # about the package, and no compile is tried after it.
  #
  # `opts`: `releases:`, the snapshot after the project's first `deps.get`;
  # `run_started_at:`; `log_tail_bytes:`. Public for tests, which inject
  # `host_trace:` (`HostTrace.compile/4`'s shape), `optional_deps:` (`fn
  # project_dir, package -> {deps, skipped} end`) and `deps_get:`
  # (`Project.add_optional_deps/5`'s); none of the three reaches the traced
  # compile.
  @spec toolchain_compile(String.t(), String.t() | nil, String.t(), map(), keyword()) ::
          {:ok, %{host: map(), verdict: Portability.verdict(), optional_deps: map() | nil}}
          | {:error, term()}
  def toolchain_compile(project_dir, "exclude", package_name, paths, opts) do
    with {:ok, compiled} <- host_trace(project_dir, package_name, paths, opts) do
      info = Map.put(optional_deps_info([], [], "not_requested"), :skipped, [])
      {:ok, Map.put(compiled, :optional_deps, info)}
    end
  end

  def toolchain_compile(project_dir, _request, package_name, paths, opts) do
    resolve = Keyword.get(opts, :optional_deps, &optional_deps_to_add/2)
    {deps, skipped} = resolve.(project_dir, package_name)

    if skipped != [] do
      log_host(
        paths,
        "Not adding optional dependencies #{Enum.join(skipped, ", ")}: " <>
          "tooling or alternatives most applications do not lock"
      )
    end

    with {:ok, compiled} <- compile_with_optional(deps, project_dir, package_name, paths, opts) do
      {:ok, Map.update!(compiled, :optional_deps, &put_skipped(&1, skipped))}
    end
  end

  defp optional_deps_to_add(project_dir, package_name) do
    project_dir
    |> DepsLock.unresolved_optional_deps(package_name)
    |> Project.optional_deps_to_add()
  end

  defp put_skipped(nil, _skipped), do: nil
  defp put_skipped(info, skipped), do: Map.put(info, :skipped, skipped)

  # `HostTrace.compile/4`'s own `deps_get:` takes three arguments, so the
  # caller's injections are dropped before the options reach it.
  defp host_trace(project_dir, package_name, paths, opts) do
    trace = Keyword.get(opts, :host_trace, &HostTrace.compile/4)
    forwarded = Keyword.drop(opts, [:deps_get, :optional_deps, :host_trace])

    case guarded_host_trace(trace, project_dir, package_name, paths, forwarded) do
      {:ok, %{host: %{status: :error} = host}} -> {:error, {:host_compile_error, host[:error]}}
      other -> other
    end
  end

  defp guarded_host_trace(trace, project_dir, package_name, paths, opts) do
    {:ok, trace.(project_dir, package_name, paths, opts)}
  rescue
    e -> {:error, {:host_compile_crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:host_compile_crashed, "#{kind} #{inspect(reason, limit: 20)}"}}
  end

  defp compile_with_optional([], project_dir, package_name, paths, opts) do
    with {:ok, compiled} <- host_trace(project_dir, package_name, paths, opts) do
      {:ok, Map.put(compiled, :optional_deps, passed_info(compiled, [], [], nil))}
    end
  end

  defp compile_with_optional(deps, project_dir, package_name, paths, opts) do
    log_host(
      paths,
      "Adding optional dependencies: " <>
        Enum.map_join(deps, ", ", &"#{&1.app} #{&1.requirement}")
    )

    with {:ok, snapshot} <- Project.snapshot(project_dir) do
      case add_optional(project_dir, package_name, deps, opts) do
        {:ok, []} ->
          compile_with_optional([], project_dir, package_name, paths, opts)

        {:ok, added} ->
          compile_added(added, snapshot, project_dir, package_name, paths, opts)

        {:error, {:restore_failed, _reason, _cause}} = error ->
          error

        # Restored already; compiled without them from a clean `_build/host`.
        {:error, reason} ->
          names = Enum.map(deps, & &1.app)

          compile_without(project_dir, package_name, paths, opts, snapshot, names, %{
            why: drop_why(reason),
            detail: reason,
            reason: drop_reason(reason)
          })
      end
    end
  end

  defp add_optional(project_dir, package_name, deps, opts) do
    env = host_env(project_dir)

    case Keyword.fetch(opts, :deps_get) do
      {:ok, deps_get} -> Project.add_optional_deps(project_dir, package_name, deps, env, deps_get)
      :error -> Project.add_optional_deps(project_dir, package_name, deps, env)
    end
  end

  defp compile_added(added, snapshot, project_dir, package_name, paths, opts) do
    with {:policy, :ok} <- {:policy, LockPolicy.validate(project_dir)},
         # After the `deps.get` that fetched them, before their compile.
         with_opts = Keyword.put(opts, :releases, Portability.lock_snapshot(project_dir)),
         {:ok, %{host: %{status: :pass}} = compiled} <-
           host_trace(project_dir, package_name, paths, with_opts) do
      {:ok, Map.put(compiled, :optional_deps, optional_deps_info(added, [], nil))}
    else
      {:policy, {:error, reason}} ->
        compile_without(project_dir, package_name, paths, opts, snapshot, added, %{
          why: "they bring in a dependency the lock policy rejects",
          detail: reason,
          reason: "lock_policy_violation"
        })

      {:ok, %{host: host}} ->
        compile_without(project_dir, package_name, paths, opts, snapshot, added, %{
          why: "the host compile failed with them",
          detail: host[:error],
          reason: "host_compile_failed"
        })

      {:error, _reason} = error ->
        error
    end
  end

  # From a clean `_build/host`: nothing the compile with them built may
  # stay. HostTrace's own `deps.get` re-resolves the restored `mix.exs`.
  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp compile_without(project_dir, package_name, paths, opts, snapshot, added, drop) do
    log_host(paths, drop_warning(added, drop.why, drop.detail))
    revert = Project.drop_optional_deps(snapshot, package_name, host_env(project_dir))

    with {:revert, :ok} <- {:revert, revert},
         {:revert, {:ok, _}} <- {:revert, File.rm_rf(Path.join([project_dir, "_build", "host"]))},
         {:ok, compiled} <- host_trace(project_dir, package_name, paths, opts),
         :ok <- in_time(compiled.host, drop) do
      {:ok, Map.put(compiled, :optional_deps, passed_info(compiled, [], added, drop.reason))}
    else
      {:revert, {:error, reason}} -> {:error, {:optional_deps_revert_failed, reason}}
      {:revert, {:error, reason, _path}} -> {:error, {:optional_deps_revert_failed, reason}}
      {:error, _reason} = error -> error
    end
  end

  # After a compile with them failed, the one without them may find the run
  # used up: no verdict on the package, so a retryable worker failure. With
  # no compile before it (a `deps.get` or lock-policy drop), the time it
  # lacked is the package's own, as for a run's only compile.
  defp in_time(host, %{reason: "host_compile_failed"}) do
    if HostTrace.out_of_time?(host),
      do: {:error, {:no_time_left_without_optional_deps, host.error}},
      else: :ok
  end

  defp in_time(_host, _drop), do: :ok

  defp passed_info(%{host: %{status: :pass}}, added, dropped, reason),
    do: optional_deps_info(added, dropped, reason)

  defp passed_info(_compiled, _added, _dropped, _reason), do: nil

  # The traced judge compile (`NccWorker.Portability.run/3`) of the full
  # run's `pure_elixir` path (`full_run_portability/3`). A full run's closure
  # is compiled by nerves_bootstrap inside `mix deps.get`, so its host
  # compile cannot be the traced one, and this recompiles the closure. It
  # runs with the host compile's env and its own `HEX_HOME`, exactly as
  # `compile_host/4` does, and judges dependency sources against the run's
  # Hex cache (the one `package_tarball/2` reads). `opts`: `releases:`, the
  # `Portability.lock_snapshot/1` matching the build being judged
  # (`judge_releases/2`), and `run_started_at:`, the run's start (`input.started_at`),
  # which bounds the compile by what is left of the run. It writes only under
  # `<work>/trace` and `<out>/logs/host-trace.log` (`setup_paths/1` made
  # `<out>/logs` at the run's start). A trace that fails is "portability
  # could not be judged" and changes no host status; `Portability.run/3`
  # never raises, but `HexHome` may, which the caller guards against
  # (`full_run_portability/3`).
  defp run_portability(project_dir, package_name, paths, opts) do
    hex_home = HexHome.prepare(project_dir, "host")

    verdict =
      Portability.run(
        project_dir,
        package_name,
        [
          env: host_env(project_dir) ++ hex_env(hex_home),
          releases: Keyword.get(opts, :releases),
          hex_home: System.get_env("HEX_HOME"),
          run_started_at: Keyword.get(opts, :run_started_at),
          trace_dir: Path.join(paths.work_dir, "trace"),
          log_file: Path.join([paths.output_dir, "logs", "host-trace.log"])
        ] ++ Keyword.take(opts, [:timeout_ms, :cmd])
      )

    HexHome.publish(hex_home)
    verdict
  end

  @doc false
  # The lock snapshot the traced judge compile uses, and the optional-deps
  # info without it (it is not part of `result.json`). A build published with
  # its optional deps added is judged against the snapshot taken right after
  # the `deps.get` that fetched them, before their compile
  # (`build_with_optional_deps/5`); every other build, against `first`, taken
  # after the project's first `deps.get` and before any compile. Public for
  # tests.
  @spec judge_releases(term(), term()) :: {term(), term()}
  def judge_releases(_first, %{added: [_ | _], lock_snapshot: releases} = info),
    do: {releases, Map.delete(info, :lock_snapshot)}

  def judge_releases(first, %{} = info), do: {first, Map.delete(info, :lock_snapshot)}
  def judge_releases(first, info), do: {first, info}

  defp put_requested_toolchain(result, requested) when is_map(requested),
    do: Map.put(result, :requested_toolchain, requested)

  defp put_requested_toolchain(result, _requested), do: result

  @doc false
  # The input's `optional_deps` request echoed back, which the portal checks
  # against the variant the job was queued for. Public for tests.
  @spec put_requested_optional_deps(map(), term()) :: map()
  def put_requested_optional_deps(result, requested) when requested in ["include", "exclude"],
    do: Map.put(result, :requested_optional_deps, requested)

  def put_requested_optional_deps(result, _requested), do: result

  @doc """
  A toolchain run's `toolchain_build` (see `t:toolchain_build/0`) from its
  host compile, the package's host build under
  `<project_dir>/_build/host/lib/<package_name>`, and the compile-time
  trace's verdict (`NccWorker.Portability.run/3`; `nil` when there was none,
  which cannot pass).
  """
  @spec toolchain_build(String.t(), String.t(), map(), map(), Portability.verdict() | nil) ::
          toolchain_build()
  def toolchain_build(project_dir, package_name, host_result, toolchain, portability) do
    build = %{
      status: "error",
      reason: nil,
      elixir: toolchain.elixir,
      otp: toolchain.erlang,
      deps_lock: nil,
      package_checksum: nil,
      compile_env: nil,
      compile_env_rule: nil,
      file_manifest: nil,
      portability_rule: nil,
      rule1_reason: nil,
      compile_observations: nil
    }

    case host_result do
      %{status: :pass} ->
        judge_toolchain_build(build, project_dir, package_name, portability, host_result)

      host ->
        %{build | reason: "host compile failed: " <> describe_error(host[:error])}
    end
  end

  defp judge_toolchain_build(build, project_dir, package_name, portability, host_result) do
    portability = require_compile_env(portability || not_traced())

    if unfinished?(portability),
      do: unjudged_toolchain_build(build, project_dir, package_name, portability, host_result),
      else: judge_finished_build(build, project_dir, package_name, portability, host_result)
  end

  # The traced compile did not run to its end (a crash, a timeout, a
  # non-zero exit), so `_build/host/lib/<package>` may be half-written: rule 1
  # does not judge it, nothing is read from it (`compile_env` stays nil) and
  # the build is skipped as "portability could not be judged", never an
  # error. The lock-derived fields still describe what was built.
  defp unjudged_toolchain_build(build, project_dir, package_name, portability, host_result) do
    %{
      build
      | status: "skipped",
        reason: PortabilityReasons.could_not_judge(),
        deps_lock: DepsLock.read(project_dir, package_name),
        package_checksum: DepsLock.package_checksum(project_dir, package_name),
        portability_rule: 1,
        compile_observations: with_host_time(portability.observations, host_result)
    }
  end

  # A pass always comes from a finished compile; a skip only when the
  # verdict says the compile finished or never started.
  defp unfinished?(%{status: :pass}), do: false

  defp unfinished?(verdict),
    do:
      get_in(verdict, [:observations, "trace_stats", "judge_compile"]) not in [
        "finished",
        "not_run"
      ]

  defp judge_finished_build(build, project_dir, package_name, portability, host_result) do
    app_dir = Path.join([project_dir, "_build", "host", "lib", package_name])
    scan = scan_host_app(app_dir)
    tarball = package_tarball(project_dir, package_name)
    rule1 = BuildSelection.portable?(project_dir, package_name, scan, tarball: tarball)
    app_env = AppFile.read_compile_env(Path.join([app_dir, "ebin", "#{package_name}.app"]))
    {compile_env, compile_env_rule} = r5_compile_env(app_env, portability)

    build = %{
      build
      | deps_lock: DepsLock.read(project_dir, package_name),
        package_checksum: DepsLock.package_checksum(project_dir, package_name),
        compile_env: compile_env,
        compile_env_rule: compile_env_rule,
        portability_rule: 1,
        rule1_reason: rule1_reason(rule1),
        compile_observations: with_host_time(portability.observations, host_result)
    }

    case combine(rule1, portability) do
      :ok ->
        manifest = BeamScan.normalize(scan)["footprint"]["file_manifest"]
        %{build | status: "pass", file_manifest: manifest}

      {:skip, reason} ->
        %{build | status: "skipped", reason: reason}
    end
  end

  defp not_traced do
    %{
      status: :skip,
      reason: PortabilityReasons.could_not_judge(),
      observations: %{
        "problems" => ["not traced"],
        "trace_stats" => %{"judge_compile" => "not_run", "transient" => true}
      }
    }
  end

  defp rule1_reason(:ok), do: nil
  defp rule1_reason({:skip, reason}), do: reason

  @doc false
  # R5: a build whose trace passed lists the config reads it observed after
  # the `.app`'s own `compile_env` (`ConfigReads.merge/2`) and says so
  # (`compile_env_rule` 1); any other build keeps the `.app`'s list alone,
  # and a `.app` that could not be read stays nil. Nothing is written into
  # the `.app` itself. Public for tests.
  @spec r5_compile_env([map()] | nil, Portability.verdict() | nil) :: {[map()] | nil, 1 | nil}
  def r5_compile_env(app_env, %{status: :pass, compile_env: items})
      when is_list(app_env) and is_list(items),
      do: {ConfigReads.merge(app_env, items), 1}

  def r5_compile_env(app_env, _verdict), do: {app_env, nil}

  # A pass names the config reads its files depend on (`compile_env`, `[]`
  # for none). One that does not could have dropped them, so it is judged
  # as a trace that could not be used: it never publishes.
  defp require_compile_env(%{status: :pass, compile_env: items} = verdict) when is_list(items),
    do: verdict

  defp require_compile_env(%{status: :pass} = verdict),
    do: cannot_judge(verdict, "pass without config reads")

  defp require_compile_env(verdict), do: verdict

  # A verdict turned into a could-not-judge for `problem`; it keeps what the
  # trace observed and names the problem first.
  defp cannot_judge(verdict, problem) do
    observations = Map.get(verdict, :observations) || %{}
    problems = [problem | Map.get(observations, "problems", [])]

    verdict
    |> Map.merge(%{status: :skip, reason: PortabilityReasons.could_not_judge()})
    |> Map.put(:observations, Map.put(observations, "problems", problems))
    |> Map.delete(:compile_env)
  end

  # The host compile's own wall time (its `deps.get` included) next to the
  # traced judge compile's `wall_ms`, for the P1 benchmark (spec section 11).
  defp with_host_time(observations, host_result) do
    seconds = host_result[:duration_sec]
    stats = Map.get(observations, "trace_stats") || %{}
    Map.put(observations, "trace_stats", Map.put(stats, "host_compile_sec", seconds))
  end

  defp put_host_time(%{observations: %{} = observations} = verdict, seconds),
    do: %{verdict | observations: with_host_time(observations, %{duration_sec: seconds})}

  defp put_host_time(verdict, _seconds), do: verdict

  @doc false
  # P1 is rule 1 AND the trace. Reason precedence: both pass -> pass; a trace
  # refusal wins over rule 1's reason (it is the more precise one); when the
  # trace could not judge, rule 1's own skip reason is kept, so the row stays
  # reopenable when P4 relaxes rule 1, and a rule 1 pass becomes "portability
  # could not be judged". Public for tests.
  @spec combine(:ok | {:skip, String.t()}, Portability.verdict()) :: :ok | {:skip, String.t()}
  def combine(:ok, %{status: :pass}), do: :ok
  def combine(:ok, %{reason: reason}) when is_binary(reason), do: {:skip, reason}
  def combine(:ok, _verdict), do: {:skip, PortabilityReasons.could_not_judge()}
  def combine({:skip, _reason} = rule1, %{status: :pass}), do: rule1

  def combine({:skip, rule1_reason}, verdict) do
    reason = verdict[:reason]
    if PortabilityReasons.refusal?(reason), do: {:skip, reason}, else: {:skip, rule1_reason}
  end

  # The package's own Hex tarball, the reference `BuildSelection.portable?/4`
  # judges its priv files against. `deps.get` left it in the run's Hex cache
  # (`NccWorker.HexCache`), whose `HEX_HOME` every `mix` here inherits, and
  # it is used only while it is still the tarball the lock names: read once,
  # its bytes are both what is checked against the lock and what is judged.
  defp package_tarball(project_dir, package_name) do
    with {:ok, release} <- DepsLock.package_release(project_dir, package_name),
         home when is_binary(home) and home != "" <- System.get_env("HEX_HOME"),
         bytes when is_binary(bytes) <-
           HexCache.package_tarball(home, release.name, release.version, release.checksum) do
      {:binary, bytes}
    else
      _ -> nil
    end
  end

  # The raw `BeamScanner` result, which `portable?/4` reads. A missing or
  # unreadable build reads as no beams, so it is skipped rather than passed.
  defp scan_host_app(app_dir) do
    if File.dir?(app_dir), do: BeamScanner.analyze(app_dir), else: %{beam_count: 0}
  rescue
    _ -> %{beam_count: 0}
  end

  defp describe_error(error) when is_binary(error), do: error
  defp describe_error(nil), do: "unknown error"
  defp describe_error(error), do: inspect(error, limit: 20)

  defp package_footprint(:pure_elixir, _project, _package, _systems), do: empty_footprint()

  defp package_footprint(:firmware, project, package, systems) do
    case Footprint.calculate(project, package, systems) do
      {:ok, stats} ->
        stats

      {:error, reason} ->
        IO.puts(:stderr, "Warning: Failed to calculate footprint: #{inspect(reason)}")
        empty_footprint()
    end
  end

  @spec validate_input(input()) :: :ok | {:error, term()}
  defp validate_input(input) do
    with :ok <- validate_run_id(input),
         :ok <- validate_image(input) do
      validate_package(input)
    end
  end

  defp validate_run_id(input) do
    if is_binary(input[:run_id]) && input.run_id != "",
      do: :ok,
      else: {:error, :missing_run_id}
  end

  defp validate_image(input) do
    cond do
      !is_map(input[:image]) ->
        {:error, :missing_image}

      !is_binary(get_in(input, [:image, :name])) ->
        {:error, :missing_image_name}

      !is_binary(get_in(input, [:image, :digest])) ->
        {:error, :missing_image_digest}

      true ->
        :ok
    end
  end

  # A warm run fills the Nerves cache and builds no package.
  defp validate_package(input) do
    cond do
      RunScope.from_input(input) == :warm_nerves ->
        :ok

      !is_map(input[:package]) ->
        {:error, :missing_package}

      !is_binary(get_in(input, [:package, :name])) ->
        {:error, :missing_package_name}

      true ->
        :ok
    end
  end

  @spec setup_paths(input()) :: {:ok, map()} | {:error, term()}
  # Paths are supplied by the runner/CLI operator for the disposable build container.
  # sobelow_skip ["Traversal.FileModule"]
  defp setup_paths(input) do
    work_dir = get_in(input, [:paths, :work_dir]) || "/work"
    output_dir = get_in(input, [:paths, :output_dir]) || "/out"

    # Ensure output directories exist
    logs_dir = Path.join(output_dir, "logs")
    File.mkdir_p!(logs_dir)

    {:ok, %{work_dir: work_dir, output_dir: output_dir, logs_dir: logs_dir}}
  end

  # A toolchain image has no nerves_bootstrap, so a toolchain run does not
  # probe for it and records "absent".
  @doc false
  @spec detect_toolchain(RunScope.t()) :: {:ok, map()} | {:error, term()}
  def detect_toolchain(scope) do
    elixir_version = System.version()
    erlang_version = :erlang.system_info(:otp_release) |> to_string()

    mix_version =
      case System.cmd("mix", ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(&1, "Mix"))
          |> then(&if &1, do: String.replace(&1, "Mix ", ""), else: "unknown")

        _ ->
          "unknown"
      end

    nerves_bootstrap_version =
      if scope == :toolchain, do: "absent", else: nerves_bootstrap_version()

    {:ok,
     %{
       elixir: elixir_version,
       erlang: erlang_version,
       mix: mix_version,
       nerves_bootstrap: nerves_bootstrap_version
     }}
  end

  defp nerves_bootstrap_version do
    case System.cmd("mix", ["nerves.info"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "nerves_bootstrap"))
        |> then(fn
          nil -> nil
          line -> Regex.run(~r/(\d+\.\d+\.\d+)/, line) |> List.last()
        end)

      _ ->
        nil
    end
  end

  @spec build_all_systems(
          String.t(),
          list(),
          String.t(),
          integer(),
          integer(),
          String.t(),
          map() | nil
        ) :: {map(), %{String.t() => [{String.t(), String.t()}]}}
  defp build_all_systems(
         project_dir,
         [_, _ | _] = systems,
         output_dir,
         timeout,
         log_tail_bytes,
         package_name,
         host_result
       ) do
    if SeedGate.gate?(host_result) do
      {seed, rest} = SeedGate.split(systems)

      # See `NccWorker.SeedGate`. Only the seed is prepared up front: a run that
      # stops after it skips seven `mix deps.get`s as well as seven builds.
      seed_prepared = [{seed, prepare_system(project_dir, seed, output_dir, package_name)}]
      seed_results = build_batch(seed_prepared, 1, log_tail_bytes, package_name)

      [{_name, seed_result}] = seed_results

      {rest_results, rest_prepared} =
        if SeedGate.skip_rest?(seed_result) do
          {Enum.map(rest, &{&1.name, SeedGate.skipped_result(seed.name)}), []}
        else
          prepared =
            Enum.map(rest, &{&1, prepare_system(project_dir, &1, output_dir, package_name)})

          {build_batch(prepared, build_concurrency(), log_tail_bytes, package_name), prepared}
        end

      {Map.new(seed_results ++ rest_results), prepared_envs(seed_prepared ++ rest_prepared)}
    else
      build_all_systems(project_dir, systems, output_dir, timeout, log_tail_bytes, package_name)
    end
  end

  defp build_all_systems(
         project_dir,
         systems,
         output_dir,
         timeout,
         log_tail_bytes,
         package_name,
         _host_result
       ) do
    build_all_systems(project_dir, systems, output_dir, timeout, log_tail_bytes, package_name)
  end

  defp build_all_systems(project_dir, systems, output_dir, _timeout, log_tail_bytes, package_name) do
    # Two phases, deliberately.
    #
    # `mix deps.get` resolves against the one `mix.lock` in the project root and
    # writes it back, so those runs stay serial: two targets fetching at the same
    # time race on that file. They are cheap anyway, the hex cache is mounted and
    # warm by the time we get here.
    #
    # The firmware builds are the expensive half and now share nothing. Each
    # target already had its own `MIX_BUILD_PATH`; giving it its own
    # `MIX_DEPS_PATH` too costs a little disk and unpack time, and keeps deps
    # that compile inside their own source tree (anything on elixir_make) from
    # clobbering each other across targets.
    #
    # Most of a dependency tree is target-independent and one build of it can
    # serve every target (see `NccWorker.BuildCache`). But the run-local tier
    # only gets those builds once a target finishes, and with every target
    # starting at once on a cold cache none of them can use another's:
    # phoenix_kit_ai compiled 67 shareable dependencies eight times over, an
    # hour in all. So when enough of them are missing from both the shared
    # root and the run-local tier, one target builds alone first and the rest
    # restore from it (now from the run-local tier) just before they compile.
    # On a warm shared cache that would only cost a wave of parallel firmware
    # assembly, so it is skipped.
    concurrency = build_concurrency()

    prepared =
      Enum.map(systems, fn system ->
        {system, prepare_system(project_dir, system, output_dir, package_name)}
      end)

    {seed, rest} = split_seed(prepared, concurrency)

    results =
      (build_batch(seed, 1, log_tail_bytes, package_name) ++
         build_batch(rest, concurrency, log_tail_bytes, package_name))
      |> Map.new()

    {results, prepared_envs(prepared)}
  end

  # Each prepared system's build env, by name, for the optional-dependency
  # pass to build exactly where the firmware build did.
  defp prepared_envs(prepared),
    do: Map.new(prepared, fn {system, prep} -> {system.name, prep.env} end)

  defp split_seed(prepared, concurrency) when concurrency > 1 and length(prepared) > 1 do
    case Enum.split_with(prepared, fn {_system, prep} -> prep.deps == :ok end) do
      {[{_system, prep} = first | ok], failed} ->
        if BuildCache.missing_shared(prep.cache_plan) >= @seed_min_missing_shared,
          do: {[first], ok ++ failed},
          else: {[], prepared}

      _ ->
        {[], prepared}
    end
  end

  defp split_seed(prepared, _concurrency), do: {[], prepared}

  defp build_batch(batch, concurrency, log_tail_bytes, package_name) do
    batch
    |> Task.async_stream(
      fn {system, prep} -> build_system(system, prep, log_tail_bytes, package_name) end,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Enum.zip(batch)
    |> Enum.map(fn
      {{:ok, result}, {system, _prep}} ->
        {system.name, result}

      {{:exit, reason}, {system, prep}} ->
        {system.name, task_crash_result(prep, log_tail_bytes, reason)}
    end)
  end

  # How many targets may build at once. One is the historical serial behaviour
  # and stays the default: the limit that matters is the CPU cap on the whole
  # container, which the deployment knows about and this code does not.
  #
  # Capped at @max_build_concurrency, which is about the machine rather than
  # correctness: targets share one project dir and one Hex cache, and past a
  # handful of concurrent Buildroot builds the host stops being usable for
  # anything else.
  defp build_concurrency do
    case Integer.parse(System.get_env("NCC_BUILD_CONCURRENCY", "1")) do
      {n, _} when n > 0 -> min(n, @max_build_concurrency)
      _ -> 1
    end
  end

  # Serial phase: fetch this target's deps, restore whatever the build cache
  # already has for them, and hand the rest to the parallel phase.
  # `deps_duration` is carried across so the reported duration still covers the
  # whole target, not just the part that ran concurrently.
  #
  # The cache work belongs here rather than alongside the compile because
  # `BuildCache.plan/6` shells out to `mix deps.tree`, which writes a file into
  # the project root: two targets doing that at once would race on it. This
  # phase is serial by construction, so they cannot.
  @spec prepare_system(String.t(), map(), String.t(), String.t()) :: map()
  # output_dir is the worker output mount and system names come from Systems.select/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_system(project_dir, system, output_dir, package_name) do
    log_file = Path.join([output_dir, "logs", "#{system.name}.log"])
    build_path = Path.join([project_dir, "_build", system.target])
    deps_path = Path.join([project_dir, "deps_#{system.target}"])
    out_root = Path.join(output_dir, "build-cache")
    start_time = System.monotonic_time(:second)

    hex_home = HexHome.prepare(project_dir, system.target)

    env =
      [
        {"MIX_TARGET", system.target},
        {"MIX_BUILD_PATH", build_path},
        {"MIX_DEPS_PATH", deps_path},
        {"MIX_ENV", "prod"}
      ] ++ hex_env(hex_home)

    deps =
      case System.cmd("mix", ["deps.get"],
             cd: project_dir,
             env: env,
             stderr_to_stdout: true,
             into: File.stream!(log_file, [:append])
           ) do
        {_, 0} -> :ok
        {_, exit_code} -> {:error, exit_code}
      end

    {cache_plan, cache_stats} =
      case deps do
        :ok -> restore_cache(project_dir, deps_path, build_path, system.target, env, package_name)
        _ -> {:disabled, %{}}
      end

    %{
      project_dir: project_dir,
      log_file: log_file,
      build_path: build_path,
      env: env,
      hex_home: hex_home,
      deps: deps,
      cache_plan: cache_plan,
      cache_stats: cache_stats,
      out_root: out_root,
      deps_duration: System.monotonic_time(:second) - start_time
    }
  end

  # Fills `_build/<target>/lib` from the shared root and the run-local tier
  # before anything compiles, and reports what it managed to fill in. The
  # counts ride along in `phase_timings` because a cache whose hit rate nobody
  # can see is a cache nobody can tell is broken: a key that is too specific
  # still produces correct builds, just slow ones, and this is the only signal
  # that separates the two.
  defp restore_cache(project_dir, deps_path, build_path, target, env, package_name) do
    plan =
      BuildCache.plan(project_dir, deps_path, build_path, target, env,
        exclude: [@wrapper_app],
        package: package_name
      )

    {restored, total} = BuildCache.restore(plan)
    {plan, %{cache_restored: restored * 1.0, cache_candidates: total * 1.0}}
  end

  # The restore in prepare_system/4 runs for every target before any of them
  # has compiled, so it never sees what an earlier target in this same run
  # stored into the run-local tier. Restoring again right before the compile
  # picks that up. It only fills directories that are still missing, so
  # nothing restored or built already is touched.
  defp restore_again(%{cache_plan: plan} = prep) do
    {restored, _total} = BuildCache.restore(plan)

    update_in(
      prep.cache_stats,
      &Map.update(&1, :cache_restored, restored * 1.0, fn n -> n + restored end)
    )
  end

  @spec build_system(map(), map(), integer(), String.t()) :: map()
  defp build_system(system, prep, log_tail_bytes, package_name) do
    result =
      case prep.deps do
        :ok ->
          prep = restore_again(prep)

          prep
          |> run_firmware(log_tail_bytes, package_name)
          |> store_cache(prep)
          |> Map.put(
            :system_version,
            system_version(prep.project_dir, prep.log_file, system.name)
          )

        {:error, exit_code} ->
          failed_system_result(
            prep,
            log_tail_bytes,
            "mix deps.get exited with code #{exit_code}"
          )
      end

    # Also on the failure path: `mix deps.get` already ran, so this build's
    # registry may be ahead of the shared one even when nothing compiled.
    HexHome.publish(prep.hex_home)

    result
  end

  defp hex_env(nil), do: []
  defp hex_env(dir), do: [{"HEX_HOME", dir}]

  # Only a passing build gets stored. A failure can leave a dependency directory
  # that Mix abandoned partway through, and there is no way to tell that apart
  # from a complete one after the fact.
  defp store_cache(%{status: :pass} = result, prep) do
    candidates = BuildCache.store(prep.cache_plan, prep.out_root)

    result
    |> Map.update!(:phase_timings, &Map.merge(&1, prep.cache_stats))
    |> put_in([:phase_timings, :cache_stored], length(candidates) * 1.0)
    |> Map.put(:cache_candidates, candidates)
  end

  defp store_cache(result, prep) do
    result
    |> Map.update(:phase_timings, prep.cache_stats, &Map.merge(&1, prep.cache_stats))
    |> Map.put(:cache_candidates, [])
  end

  defp task_crash_result(prep, log_tail_bytes, reason) do
    failed_system_result(prep, log_tail_bytes, "build task exited: #{inspect(reason)}")
  end

  defp failed_system_result(prep, log_tail_bytes, error) do
    %{
      status: :fail,
      duration_sec: prep.deps_duration * 1.0,
      phase_timings: %{deps_sec: prep.deps_duration * 1.0},
      firmware_size_bytes: nil,
      log_tail: prep.log_file |> read_log_tail(log_tail_bytes) |> LogTail.with_error(error),
      system_version: nil,
      beam_scan: nil,
      dependency_scans: nil,
      error: error
    }
  end

  # The phase split is the point, not a nicety, but the labels no longer mean
  # what they did. `mix deps.get` used to compile the whole tree by way of
  # nerves_bootstrap; since it stopped doing that, `deps_sec` is fetch and unpack
  # only and the tree compiles inside `mix firmware`. So `firmware_sec` is now
  # compile cost plus image assembly.
  #
  # Compiling dominates in aggregate, which is what made the build cache worth
  # its correctness risk, but the ratio is very target-dependent and the earlier
  # "18 seconds of assembly" figure here was an x86_64-only measurement. Timing
  # the gap between the last beam written and the .fw appearing gives assembly
  # costs of 115 to 421 seconds on the ARM targets. For a small package that is
  # most of the build: bencoding on rpi4 was 42s of compiling against 176s of
  # assembly. Caching dep compiles therefore cannot help those builds much, and
  # a flat firmware_sec hides which half a given package is paying for.
  @spec run_firmware(map(), integer(), String.t()) :: map()
  defp run_firmware(prep, log_tail_bytes, package_name) do
    %{
      project_dir: project_dir,
      env: env,
      log_file: log_file,
      build_path: build_path,
      deps_duration: deps_duration
    } = prep

    firmware_start = System.monotonic_time(:second)

    # No second build pass. A determinism check used to rebuild the package with
    # `mix release` and compare hashes, at 20-36 s a target, but nothing outside
    # the worker ever read its verdict; its one visible effect was failing
    # targets whose package it could not locate.
    case run_firmware_mix(project_dir, env, log_file) do
      :ok ->
        firmware_sec = System.monotonic_time(:second) - firmware_start
        scan_start = System.monotonic_time(:second)
        firmware_info = Scanner.find_firmware(build_path)
        log_tail = read_log_tail(log_file, log_tail_bytes)
        beam_scan = analyze_beam_scan(build_path, package_name)
        dependency_scans = analyze_dependency_beam_scans(build_path, package_name)
        compile_env = compile_env_for(build_path, package_name)
        scan_sec = System.monotonic_time(:second) - scan_start
        duration = deps_duration + (System.monotonic_time(:second) - firmware_start)

        %{
          status: :pass,
          duration_sec: duration * 1.0,
          phase_timings: %{
            deps_sec: deps_duration * 1.0,
            firmware_sec: firmware_sec * 1.0,
            scan_sec: scan_sec * 1.0
          },
          firmware_size_bytes: firmware_info[:size],
          log_tail: log_tail,
          compile_env: compile_env,
          beam_scan: beam_scan,
          dependency_scans: dependency_scans,
          error: nil
        }

      {:error, error} ->
        duration = deps_duration + (System.monotonic_time(:second) - firmware_start)
        log_tail = log_file |> read_log_tail(log_tail_bytes) |> LogTail.with_error(error)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          phase_timings: %{deps_sec: deps_duration * 1.0},
          firmware_size_bytes: nil,
          log_tail: log_tail,
          beam_scan: nil,
          dependency_scans: nil,
          error: error
        }
    end
  end

  defp run_mix(args, project_dir, env, log_file) do
    run_cmd("mix", args, project_dir, env, log_file)
  end

  defp compile_env_for(build_path, package_name) do
    case AppFile.find_app_in_build(build_path, package_name) do
      nil -> nil
      app -> AppFile.read_compile_env(app)
    end
  end

  # The host compile's `.app` sits directly under `build_path/lib`, unlike a
  # firmware target's release copy under `rel/*/lib/<package>-<vsn>`, because
  # the host build never runs `mix release`. Same path shape `pure_elixir_result/3`
  # reads for a pure-Elixir package's assumed-compatible result.
  @doc false
  @spec host_compile_env(String.t(), String.t()) :: [map()] | nil
  def host_compile_env(build_path, package_name) do
    AppFile.read_compile_env(
      Path.join([build_path, "lib", package_name, "ebin", "#{package_name}.app"])
    )
  end

  # Assembling a firmware image runs mksquashfs, which sets ownership on the
  # rootfs entries it packs. The build container runs with --cap-drop=ALL, so
  # those chowns come back "Operation not permitted" and the build dies partway
  # through the image (nerves_system_x86_64 hits it on /var/www; systems whose
  # overlay carries no such entry never notice). fakeroot fakes the ownership
  # bookkeeping in userspace, so the image gets the uids it expects without
  # granting CAP_CHOWN to a container that compiles untrusted package code.
  #
  # Absent fakeroot the plain command still runs, so an older image keeps its
  # current behaviour rather than failing to start.
  defp run_firmware_mix(project_dir, env, log_file) do
    case System.find_executable("fakeroot") do
      nil -> run_cmd("mix", ["firmware"], project_dir, env, log_file)
      fakeroot -> run_cmd(fakeroot, ["mix", "firmware"], project_dir, env, log_file)
    end
  end

  # Private callers choose mix or the resolved fakeroot executable and literal argument lists.
  # System.cmd passes argv directly (no shell); log_file is a worker-generated output path.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp run_cmd(command, args, project_dir, env, log_file) do
    case System.cmd(command, args,
           cd: project_dir,
           env: env,
           stderr_to_stdout: true,
           into: File.stream!(log_file, [:append])
         ) do
      {_, 0} -> :ok
      {_, exit_code} -> {:error, "mix command exited with code #{exit_code}"}
    end
  end

  # Shared with `Project.add_package/3`, and that sharing is the point. The first
  # `mix deps.get` already compiles the whole tree by way of nerves_bootstrap, so
  # it has to write into the same build path this stage reads, or the work is
  # done twice: once into `_build/dev` that nobody reads, once here.
  @spec host_env(String.t()) :: [{String.t(), String.t()}]
  defp host_env(project_dir), do: HostTrace.env(project_dir)

  @spec compile_host(String.t(), String.t(), integer(), String.t()) :: map()
  defp compile_host(project_dir, output_dir, log_tail_bytes, package_name) do
    log_file = Path.join([output_dir, "logs", "host.log"])
    start_time = System.monotonic_time(:second)

    hex_home = HexHome.prepare(project_dir, "host")
    env = host_env(project_dir) ++ hex_env(hex_home)
    build_path = Path.join([project_dir, "_build", "host"])
    out_root = Path.join(output_dir, "build-cache")

    result =
      compile_host_run(
        project_dir,
        build_path,
        env,
        log_file,
        start_time,
        log_tail_bytes,
        package_name,
        out_root
      )

    HexHome.publish(hex_home)
    result
  end

  @spec compile_host_run(
          String.t(),
          String.t(),
          list(),
          String.t(),
          integer(),
          integer(),
          String.t(),
          String.t()
        ) ::
          map()
  defp compile_host_run(
         project_dir,
         build_path,
         env,
         log_file,
         start_time,
         log_tail_bytes,
         package_name,
         out_root
       ) do
    case run_mix(["deps.get"], project_dir, env, log_file) do
      :ok ->
        deps_path = Path.join([project_dir, "deps"])

        {plan, stats} =
          restore_cache(project_dir, deps_path, build_path, "host", env, package_name)

        compile_result =
          run_compile(
            project_dir,
            env,
            log_file,
            start_time,
            log_tail_bytes,
            build_path,
            package_name
          )

        {compile_result, stats} =
          case compile_result do
            %{status: :pass} = result ->
              candidates = BuildCache.store(plan, out_root)

              {Map.put(result, :cache_candidates, candidates),
               Map.put(stats, :cache_stored, length(candidates) * 1.0)}

            result ->
              {Map.put(result, :cache_candidates, []), stats}
          end

        compile_result
        |> Map.put(:system_version, nil)
        |> Map.put(:phase_timings, stats)

      {:error, reason} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          system_version: nil,
          beam_scan: nil,
          dependency_scans: nil,
          error: reason
        }
    end
  end

  @spec run_compile(String.t(), list(), String.t(), integer(), integer(), String.t(), String.t()) ::
          map()
  defp run_compile(
         project_dir,
         env,
         log_file,
         start_time,
         log_tail_bytes,
         build_path,
         package_name
       ) do
    case run_mix(["compile"], project_dir, env, log_file) do
      :ok ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)
        compile_env = host_compile_env(build_path, package_name)

        %{
          status: :pass,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          compile_env: compile_env,
          beam_scan: nil,
          dependency_scans: nil,
          error: nil
        }

      {:error, reason} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          beam_scan: nil,
          dependency_scans: nil,
          error: reason
        }
    end
  end

  @spec read_log_tail(String.t(), integer()) :: String.t()
  # Reads a log created by this worker in the configured output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_log_tail(log_file, max_bytes) do
    case File.read(log_file) do
      {:ok, content} ->
        NccWorker.LogTail.tail(content, max_bytes)

      {:error, _} ->
        ""
    end
  end

  @spec get_package_version(String.t(), map()) :: String.t()
  defp get_package_version(_project_dir, %{version: version}) when version not in [nil, false],
    do: version

  # Reads the generated project mix.lock inside the disposable worker.
  # sobelow_skip ["Traversal.FileModule"]
  defp get_package_version(project_dir, package) do
    with {:ok, content} <- File.read(Path.join(project_dir, "mix.lock")),
         {lock, _} when is_map(lock) <- eval_lock(content),
         {_name, {:hex, _, version, _, _, _, _, _}} <-
           Enum.find(lock, fn {name, _} -> to_string(name) == package.name end) do
      version
    else
      _ -> "unknown"
    end
  end

  # Mix writes `mix.lock` with quoted keys (`"jason": {:hex, ...}`), and the
  # evaluator prints "found quoted keyword ... but the quotes are not required"
  # for every one of them. That is the lock's own generated syntax, so the
  # package being scanned can do nothing about it -- and the noise lands in the
  # build log we store and show to whoever asked for the scan, one line per
  # dependency. `with_diagnostics/1` collects the warnings instead of printing
  # them; the evaluated value is unchanged. Mirrors `NccWorker.LockPolicy`.
  # Intentional Mix lock evaluation inside the disposable build container, after deps.get
  # has already executed package build code. Never call this on the portal host;
  # container isolation, not this evaluator, is the boundary for package execution.
  # sobelow_skip ["RCE.CodeModule"]
  defp eval_lock(content) do
    {result, _diagnostics} = Code.with_diagnostics(fn -> Code.eval_string(content) end)
    result
  end

  @doc """
  The version of `system_name` the target was built against, or `nil`.

  The project's `mix.lock` is the authority: it is what `mix deps.get`
  resolved and what the firmware build then compiled. The deps.get listing in
  the target's log is only a fallback for a lock that does not name the
  system. It cannot be the source: Hex 2.6.0 stopped printing unchanged
  dependencies after resolution, so with every system already in the lock
  the listing names none of them, and a build recorded without a
  `system_version` matches no precompiled client.
  """
  @spec system_version(String.t(), String.t(), String.t()) :: String.t() | nil
  def system_version(project_dir, log_file, system_name) do
    case DepsLock.versions(project_dir) do
      {:ok, %{^system_name => version}} -> version
      _ -> extract_system_version(log_file, system_name)
    end
  end

  @spec extract_system_version(String.t(), String.t()) :: String.t() | nil
  # Reads a worker-generated per-system log in the configured output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_system_version(log_file, system_name) do
    case File.read(log_file) do
      {:ok, content} ->
        # "  nerves_system_rpi4 1.32.0" in the listing Hex printed before 2.6.0
        regex = ~r/^  #{Regex.escape(system_name)} ([\d.]+)$/m

        case Regex.run(regex, content) do
          [_, version] -> version
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp gleam_build_tool?(build_tools) do
    build_tools
    |> Enum.map(&String.downcase(to_string(&1)))
    |> Enum.any?(&(&1 == "gleam"))
  end

  defp gleam_skip_reason(build_tools) do
    tools = Enum.map_join(build_tools, ", ", &to_string/1)

    if tools == "" do
      "Package uses gleam build tool"
    else
      "Package uses gleam build tool (#{tools})"
    end
  end

  defp build_skipped_beam_scan(build_tools) do
    %{
      "flags" => %{
        "start_callback" => false,
        "nif" => false,
        "shell" => false,
        "app_env" => false,
        "os_env" => false,
        "os_exec" => false,
        "halt" => false
      },
      "start_modules" => [],
      "protocols" => %{"defined" => [], "impls" => []},
      "evidence" => %{
        "nif" => [],
        "shell" => [],
        "app_env" => [],
        "os_env" => [],
        "os_exec" => [],
        "halt" => []
      },
      "languages" =>
        build_tools
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.uniq(),
      "beam_count" => nil,
      "errors" => ["beam scan skipped: gleam build tool"]
    }
  end

  # Writes a fixed forced-skip log name beneath the runner-configured output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp build_forced_skip_system(output_dir, reason, log_tail_bytes, beam_scan) do
    log_file = Path.join([output_dir, "logs", "#{@forced_skip_system}.log"])
    :ok = File.write!(log_file, reason <> "\n")
    log_tail = truncate_tail(reason, log_tail_bytes)

    %{
      @forced_skip_system => %{
        status: :skipped,
        duration_sec: 0.0,
        firmware_size_bytes: nil,
        log_tail: log_tail,
        system_version: nil,
        beam_scan: beam_scan,
        dependency_scans: nil,
        error: reason
      }
    }
  end

  defp truncate_tail(message, max_bytes) when is_binary(message),
    do: NccWorker.LogTail.tail(message, max_bytes)

  defp format_retired_reason(retired) when is_map(retired) do
    reason_code = Map.get(retired, "reason") || Map.get(retired, :reason)
    message = Map.get(retired, "message") || Map.get(retired, :message) || ""
    msg = String.trim(message)

    base_reason = retired_reason_to_string(reason_code)
    base = "Package retired on hex.pm" <> if(base_reason, do: " (#{base_reason})", else: "")

    if msg != "" do
      base <> ": " <> msg
    else
      base
    end
  end

  defp format_retired_reason(_), do: "Package retired on hex.pm"

  defp retired_reason_to_string(reason) when is_binary(reason), do: reason
  defp retired_reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp retired_reason_to_string(reason) when is_integer(reason) do
    case reason do
      0 -> "other"
      1 -> "invalid"
      2 -> "security"
      3 -> "deprecated"
      4 -> "renamed"
      _ -> Integer.to_string(reason)
    end
  end

  defp retired_reason_to_string(_), do: nil

  defp analyze_beam_scan(build_path, package_name) do
    case BeamScan.analyze(build_path, package_name) do
      {:ok, scan} -> scan
      {:error, reason} -> %{"errors" => ["beam scan failed: #{inspect(reason)}"]}
    end
  end

  defp analyze_dependency_beam_scans(build_path, package_name) do
    case BeamScan.analyze_dependencies(build_path, package_name) do
      {:ok, scans} -> scans
      {:error, reason} -> %{"__errors__" => ["dependency beam scan failed: #{inspect(reason)}"]}
    end
  end

  defp empty_footprint do
    %{
      file_manifest: %{ebin: [], priv: []}
    }
  end

  defp runtime_applications(project_dir, input) do
    case NccWorker.AppFile.find_app_file(project_dir, input.package.name) do
      {:ok, app_file_path} ->
        case NccWorker.AppFile.read_applications(app_file_path) do
          {:ok, apps} ->
            apps

          {:error, reason} ->
            IO.puts(:stderr, "Warning: Failed to read .app file: #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        IO.puts(:stderr, "Warning: Failed to find .app file: #{inspect(reason)}")
        []
    end
  end
end
