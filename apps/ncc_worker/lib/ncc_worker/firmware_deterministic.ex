defmodule NccWorker.FirmwareDeterministic do
  @moduledoc """
  The deterministic sibling of a firmware target's build (`NCC_INPUT.deterministic:
  true`, the flag a toolchain run's `NccWorker.Deterministic` reads): the
  package alone compiled again for the target with
  `ERL_COMPILER_OPTIONS=deterministic`, in the target's own build env and
  build tree, over the closure the firmware build already compiled, and
  published apart from the build so that only a client whose own project
  sets exactly that option takes it.

  A sibling is its own `mix compile`, a VM started with the option, never a
  part of the firmware build's: Elixir reads `ERL_COMPILER_OPTIONS` once per
  VM. A dependency's `CInf` and `Dbgi` cannot change how a dependent
  compiles, so the closure is not compiled again (design doc, option (a)).

  It runs last, once the optional pass, the firmware world, R2
  (`NccWorker.FirmwareBuildRoot`) and the compile inputs
  (`NccWorker.FirmwareInputs`) have settled what each target publishes, and
  only on a target that passed and publishes its own build (R2 did not
  withhold it), whose build was made against the run's lock (no `deps_lock`
  of its own: a target that kept its optional dependencies was compiled
  against a closure the project no longer holds), and whose recorded
  `compile_inputs`, if any, neither read `ERL_COMPILER_OPTIONS` nor the
  whole environment. A passing target that publishes and is not eligible
  gets a `skipped` sibling with the reason; any other target gets none.

  In order (see `put/3`):

    1. Nothing when the run is past 75 minutes ("run budget exhausted").
    2. Serially, per target: its published build
       (`_build/<target>/lib/<package>`), once checked file by file against
       its manifest (`NccWorker.OptionalDepsTargets.verify_files/2`; one
       that does not hold is skipped and left alone), renamed to
       `.<package>.det-build`
       and its `priv`/`include` links made its own
       (`NccWorker.OptionalDepsTargets.own_links/1`), so nothing the
       sibling compile writes through `deps_<target>` reaches it.
    3. Concurrently: `mix compile` under `timeout(1)` in the target's env
       plus the option, into the target's log, bounded by the per-system
       timeout and the pass's budget. The package is the one app missing
       from the build path, so Mix compiles it alone.
    4. Serially, per target: writers left running reaped
       (`NccWorker.OptionalDepsTargets.reap_writers/1`); a compiled
       sibling renamed to `.<package>.deterministic`, its links owned and
       scanned there, where `NccWorker.FileArchiver` reads it; the
       published build put back and checked file by file against its
       manifest (`OptionalDepsTargets.verify_files/2`).
    5. The sibling passes only when its files are what its scan recorded,
       it lists the build's ebin and priv paths with the build's modes,
       its priv files are the build's bytes, its ebin passes
       `Compatibility.DeterministicBeams.compare_ebin/2` against the
       build's (every beam compiled with the option, Elixir code and md5
       unchanged, Erlang changes confined to what the option touches), and
       R2 passes on its own dir: the option changes an Erlang module's
       literals (`?FILE`), so its beams are judged on their own.
    6. `mix.lock` the bytes it was before the pass; one the compile
       changed is written back and every sibling of the pass is skipped.

  Anything else skips the sibling with its reason and changes nothing about
  the target: its status, firmware, log tail and files stay what they were.
  Two outcomes fail the run instead (`{:error, _}`, exit 10): a published
  build that cannot be moved back or no longer hashes to its manifest, and
  writers of a build path that survive the reap. Either may have changed
  what the run is about to archive.

  Every step that runs `mix`, scans, judges or kills goes through a runner
  (`t:runners/0`), so tests replace them.
  """

  alias Compatibility.DeterministicBeams
  alias NccWorker.{BeamScan, FirmwareBuildRoot, OptionalDepsTargets, Portability}

  @typedoc "A system's name, its Mix target, and the env and log its firmware build used."
  @type target ::
          {String.t(),
           %{target: String.t(), env: [{String.t(), String.t()}], log_file: String.t()}}

  @type ctx :: %{
          required(:enabled) => boolean(),
          required(:project_dir) => String.t(),
          required(:package) => String.t(),
          # In system order.
          required(:targets) => [target()],
          required(:timeout_sec) => pos_integer(),
          required(:concurrency) => pos_integer(),
          # The pass's wall-clock budget from its start (default 600 s).
          optional(:budget_sec) => non_neg_integer(),
          # How long the run had taken when the pass was called.
          optional(:run_elapsed_sec) => non_neg_integer()
        }

  @typedoc """
  A target's `deterministic_build`: "pass" with its own `file_manifest`
  and its R2 `build_root` (`t:NccWorker.FirmwareBuildRoot.outcome/0`), or
  "skipped" with the `reason`, no files and the R2 outcome when it got that
  far.
  """
  @type sibling :: %{
          status: String.t(),
          reason: String.t() | nil,
          erl_compiler_options: [String.t()],
          judge_revision: pos_integer(),
          file_manifest: map() | nil,
          build_root: FirmwareBuildRoot.outcome() | nil
        }

  @typedoc """
  Every key optional; a missing one runs the real thing.

    * `compile` -- `(project_dir, env, log_file, timeout_sec)`, `mix compile`
      (`OptionalDepsTargets.bounded_compile/4`); `{:error, :timeout}` when
      it ran out of time
    * `scan` -- `(app_dir)`, `NccWorker.BeamScan.analyze_app_dir/1`
    * `judge` -- `(app_dir, project_dir, target, opts)`,
      `NccWorker.FirmwareBuildRoot.judge/4`
    * `reap` -- `(build_path)`, `OptionalDepsTargets.reap_writers/1`
    * `now` -- `()`, monotonic seconds, for the budget
  """
  @type runners :: %{optional(atom()) => function()}

  @default_budget_sec 600
  @run_budget_sec 75 * 60
  @kill_grace_sec 60

  @aside "det-build"
  @sibling "deterministic"

  @kept_optional "the target's build was made with its optional dependencies"
  @reads_option "the build's compile reads ERL_COMPILER_OPTIONS"
  @scan_errors "the build's scan has errors"
  @no_beams "the build has no beams"

  @doc """
  The directory under `_build/<target>/lib` a target's sibling is read
  from, `.<package>.deterministic`, for `NccWorker.FileArchiver`.
  """
  @spec dir(String.t()) :: String.t()
  def dir(package), do: OptionalDepsTargets.variant_dir(package, @sibling)

  @doc """
  Puts a `deterministic_build` (`t:sibling/0`) on every target of
  `systems` that passed and publishes its own build (see the moduledoc).
  Returns the systems and one line per target tried, for the run's log, or
  `{:error, reason}` when a published build could not be put back as it
  was.
  """
  @spec put(%{String.t() => map()}, ctx(), runners()) ::
          {:ok, %{String.t() => map()}, [String.t()]} | {:error, term()}
  def put(systems, ctx, runners \\ %{})

  def put(systems, %{enabled: true} = ctx, runners) do
    r = Map.merge(default_runners(), runners)

    {eligible, refused} =
      ctx.targets
      |> Enum.filter(fn {name, _target} -> publishes?(systems[name]) end)
      |> Enum.split_with(fn {name, _target} -> eligible(systems[name]) == :ok end)

    systems =
      Enum.reduce(refused, systems, fn {name, _target}, acc ->
        {:skip, reason} = eligible(acc[name])
        put_sibling(acc, name, skipped(reason))
      end)

    outcome =
      cond do
        eligible == [] ->
          {:ok, systems}

        Map.get(ctx, :run_elapsed_sec, 0) > @run_budget_sec ->
          {:ok,
           Enum.reduce(eligible, systems, fn {name, _}, acc ->
             put_sibling(acc, name, skipped("run budget exhausted"))
           end)}

        true ->
          run(systems, ctx, r, eligible)
      end

    with {:ok, systems} <- outcome, do: {:ok, systems, lines(systems, ctx.targets)}
  end

  def put(systems, _ctx, _runners), do: {:ok, systems, []}

  # A passing target whose own build is published: R2 or a failed scan
  # did not take its files away.
  defp publishes?(%{status: status, beam_scan: %{"footprint" => %{"file_manifest" => %{}}}})
       when status in [:pass, "pass"],
       do: true

  defp publishes?(_result), do: false

  @doc false
  # Public for tests: `:ok` or `{:skip, reason}` for a target that publishes.
  @spec eligible(map()) :: :ok | {:skip, String.t()}
  def eligible(result) do
    scan = result.beam_scan
    inputs = Map.get(result, :compile_inputs)

    cond do
      Map.get(result, :deps_lock) != nil -> {:skip, @kept_optional}
      is_list(inputs) and Enum.any?(inputs, &option_input?/1) -> {:skip, @reads_option}
      Map.get(scan, "errors", []) != [] -> {:skip, @scan_errors}
      ebin_entries(manifest(scan)) == [] -> {:skip, @no_beams}
      true -> :ok
    end
  end

  defp option_input?(%{"kind" => "env_all"}), do: true

  defp option_input?(%{"kind" => "env", "name" => name}),
    do: name == DeterministicBeams.env_name()

  defp option_input?(_input), do: false

  defp run(systems, ctx, r, eligible) do
    deadline = r.now.() + Map.get(ctx, :budget_sec, @default_budget_sec)
    lock = read_lock(ctx.project_dir)

    with {:ok, moved, systems} <- move_all(systems, ctx, eligible),
         compiled = compile_all(ctx, r, moved, deadline),
         {:ok, systems} <- settle_all(systems, ctx, r, compiled) do
      lock_unchanged(systems, ctx.project_dir, lock, Enum.map(eligible, &elem(&1, 0)))
    end
  end

  # Serial: a target whose build is not what its scan recorded is left
  # alone (the check after the sibling would fail on it), and one whose
  # build could not be moved aside, or whose links could not be made its own
  # (then moved straight back), is skipped. A build that cannot be put back
  # is the run's error.
  defp move_all(systems, ctx, eligible) do
    Enum.reduce_while(eligible, {:ok, [], systems}, fn {name, t} = target, {:ok, moved, acc} ->
      {lib, _aside, _sibling} = dirs = paths(ctx, t)

      outcome =
        case OptionalDepsTargets.verify_files(lib, manifest(acc[name].beam_scan)) do
          :ok -> move_one(dirs)
          {:error, _} -> {:skip, "the build's files are not what its scan recorded"}
        end

      case outcome do
        :ok -> {:cont, {:ok, moved ++ [target], acc}}
        {:skip, why} -> {:cont, {:ok, moved, put_sibling(acc, name, skipped(why))}}
        {:error, reason} -> {:halt, {:error, {:deterministic_revert_failed, reason}}}
      end
    end)
  end

  defp move_one({lib, aside, _sibling}) do
    case move_aside(lib, aside) do
      {:moved, why} ->
        with :ok <- put_back(lib, aside), do: {:skip, "build links not its own: #{why}"}

      {:skip, why} ->
        {:skip, "build not moved aside: #{why}"}

      other ->
        other
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp move_aside(lib, aside) do
    with {:rm, {:ok, _}} <- {:rm, File.rm_rf(aside)},
         {:rename, :ok} <- {:rename, File.rename(lib, aside)} do
      case OptionalDepsTargets.own_links(aside) do
        :ok -> :ok
        {:error, why} -> {:moved, inspect(why)}
        {:broken, why} -> {:error, {:link_lost, why}}
      end
    else
      {:rm, {:error, why, _path}} -> {:skip, inspect(why)}
      {:rename, {:error, why}} -> {:skip, inspect(why)}
    end
  end

  defp compile_all(_ctx, _r, [], _deadline), do: []

  defp compile_all(ctx, r, moved, deadline) do
    moved
    |> Task.async_stream(&compile(ctx, r, &1, deadline),
      max_concurrency: ctx.concurrency,
      timeout: (ctx.timeout_sec + @kill_grace_sec) * 1000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(moved)
    |> Enum.map(fn
      {{:ok, outcome}, target} -> {target, outcome}
      {{:exit, _reason}, target} -> {target, {:error, "timeout"}}
    end)
  end

  defp compile(ctx, r, {_name, %{env: env, log_file: log_file}}, deadline) do
    timeout_sec = min(ctx.timeout_sec, deadline - r.now.())
    {option, value} = DeterministicBeams.env()
    env = List.keystore(env, option, 0, {option, value})

    if timeout_sec > 0 do
      append_log(log_file, "==> deterministic sibling: #{option}=#{value} mix compile")

      fn -> r.compile.(ctx.project_dir, env, log_file, timeout_sec) end
      |> safely()
      |> compiled()
    else
      {:error, "timeout"}
    end
  end

  defp compiled(:ok), do: :ok
  defp compiled({:error, :timeout}), do: {:error, "timeout"}
  defp compiled(_error), do: {:error, "compile failed"}

  # Serial, in the targets' order; the first build that cannot be put back
  # stops the pass with the run's error.
  defp settle_all(systems, ctx, r, compiled) do
    Enum.reduce_while(compiled, {:ok, systems}, fn {{name, _} = target, outcome}, {:ok, acc} ->
      case settle(ctx, r, target, outcome, acc[name]) do
        {:ok, sibling} -> {:cont, {:ok, put_sibling(acc, name, sibling)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp settle(ctx, r, {name, t} = target, outcome, result) do
    {lib, aside, sibling_dir} = paths(ctx, t)
    build_path = Path.dirname(Path.dirname(lib))

    with {:reap, :ok} <- {:reap, r.reap.(build_path)},
         {:take, {:ok, taken}} <- {:take, take(outcome, lib, sibling_dir, r)},
         {:back, :ok} <- {:back, put_back(lib, aside)},
         {:same, :ok} <-
           {:same, OptionalDepsTargets.verify_files(lib, manifest(result.beam_scan))} do
      sibling = judge(taken, ctx, r, target, {lib, sibling_dir}, result)
      append_log(t.log_file, "==> deterministic sibling: #{describe(sibling)}")
      {:ok, sibling}
    else
      {:reap, {:error, why}} -> {:error, {:deterministic_revert_failed, why}}
      {:take, {:error, why}} -> {:error, {:deterministic_revert_failed, why}}
      {:back, {:error, why}} -> {:error, {:deterministic_revert_failed, why}}
      {:same, {:error, _}} -> {:error, {:deterministic_changed_build, name}}
    end
  end

  # The sibling compile's dir: renamed to its own name, its links owned, and
  # scanned there, so what is checked is what the archiver reads. A compile
  # that failed leaves nothing; `{:error, _}` only when its dir cannot be
  # removed, and the published build then cannot go back.
  # sobelow_skip ["Traversal.FileModule"]
  defp take(:ok, lib, sibling_dir, r) do
    with {:rm, {:ok, _}} <- {:rm, File.rm_rf(sibling_dir)},
         {:rename, :ok} <- {:rename, File.rename(lib, sibling_dir)},
         {:own, :ok} <- {:own, OptionalDepsTargets.own_links(sibling_dir)},
         {:scan, {:ok, %{} = scan}} <- {:scan, safely(fn -> r.scan.(sibling_dir) end)},
         {:errors, []} <- {:errors, Map.get(scan, "errors", [])},
         %{} = sibling_manifest <- manifest(scan) do
      {:ok, {:compiled, sibling_manifest}}
    else
      {:rm, _} -> remove(lib, "a stale sibling could not be removed")
      {:rename, _} -> remove(lib, "the sibling could not be renamed")
      {:own, _} -> {:ok, {:skip, "the sibling's links are not its own"}}
      _scan -> {:ok, {:skip, "the sibling's scan failed"}}
    end
  end

  defp take({:error, why}, lib, _sibling_dir, _r), do: remove(lib, why)

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(lib, why) do
    case File.rm_rf(lib) do
      {:ok, _} -> {:ok, {:skip, why}}
      {:error, reason, path} -> {:error, {:rm_rf_failed, reason, path}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp put_back(lib, aside) do
    case File.rm_rf(lib) do
      {:ok, _} ->
        case File.rename(aside, lib) do
          :ok -> :ok
          {:error, why} -> {:error, {:rename_failed, aside, why}}
        end

      {:error, reason, path} ->
        {:error, {:rm_rf_failed, reason, path}}
    end
  end

  defp judge({:skip, why}, _ctx, _r, _target, _dirs, _result), do: skipped(why)

  defp judge({:compiled, sibling_manifest}, ctx, r, {_name, t}, {lib, sibling_dir}, result) do
    build_manifest = manifest(result.beam_scan)

    with :ok <- OptionalDepsTargets.verify_files(sibling_dir, sibling_manifest),
         :ok <- same_build(build_manifest, sibling_manifest, lib, sibling_dir) do
      verdict = safely(fn -> r.judge.(sibling_dir, ctx.project_dir, t.target, env: t.env) end)
      build_root = FirmwareBuildRoot.outcome(verdict)

      case build_root do
        %{status: "pass"} ->
          %{
            skipped(nil)
            | status: "pass",
              file_manifest: sibling_manifest,
              build_root: build_root
          }

        %{reason: reason} ->
          %{skipped("R2: " <> reason) | build_root: build_root}
      end
    else
      {:error, "files_changed"} -> skipped("the sibling's files changed after its scan")
      {:error, why} -> skipped("differs from the build: " <> why)
    end
  end

  @doc false
  # Public for tests: the sibling is the build but for what the option
  # changes (moduledoc, step 5).
  @spec same_build(map(), map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def same_build(build, sibling, build_dir, sibling_dir) do
    cond do
      shape(build) != shape(sibling) ->
        {:error, "its files are not its build's"}

      priv(build) != priv(sibling) ->
        {:error, "its priv differs"}

      true ->
        DeterministicBeams.compare_ebin(ebin(build, build_dir), ebin(sibling, sibling_dir))
    end
  end

  defp shape(manifest) do
    for key <- ["ebin", "priv"],
        do: manifest |> entries(key) |> Enum.map(&{&1["path"], &1["mode"]}) |> Enum.sort()
  end

  defp priv(manifest),
    do:
      manifest
      |> entries("priv")
      |> Enum.map(&{&1["path"], &1["mode"], &1["sha256"]})
      |> Enum.sort()

  # The manifest's ebin files, by their names, as the bytes on disk; one
  # that no longer hashes to its entry reads as missing. `app_dir` is one of
  # the run's own build dirs.
  # sobelow_skip ["Traversal.FileModule"]
  defp ebin(manifest, app_dir) do
    for %{"path" => "ebin/" <> name = path, "sha256" => sum} <- entries(manifest, "ebin"),
        {:ok, bytes} <- [File.read(Path.join(app_dir, path))],
        hex(bytes) == sum,
        into: %{},
        do: {name, bytes}
  end

  # A run whose sibling compile rewrote the lock built its siblings against
  # another closure than the builds': the lock goes back, and none is kept.
  # sobelow_skip ["Traversal.FileModule"]
  defp lock_unchanged(systems, project_dir, before, names) do
    path = Path.join(project_dir, "mix.lock")

    cond do
      read_lock(project_dir) == before ->
        {:ok, systems}

      is_binary(before) and File.write(path, before) != :ok ->
        {:error, {:deterministic_revert_failed, :lock_not_restored}}

      true ->
        reason = "the sibling compile changed mix.lock"
        {:ok, Enum.reduce(names, systems, &put_sibling(&2, &1, skipped(reason)))}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_lock(project_dir) do
    case File.read(Path.join(project_dir, "mix.lock")) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end

  defp paths(ctx, %{env: env}) do
    {_, build_path} = List.keyfind(env, "MIX_BUILD_PATH", 0)
    lib = Path.join(build_path, "lib")

    {Path.join(lib, ctx.package), Path.join(lib, ".#{ctx.package}.#{@aside}"),
     Path.join(lib, dir(ctx.package))}
  end

  defp skipped(reason) do
    %{
      status: "skipped",
      reason: reason,
      erl_compiler_options: DeterministicBeams.options(),
      judge_revision: Portability.judge_revision(),
      file_manifest: nil,
      build_root: nil
    }
  end

  defp put_sibling(systems, name, sibling),
    do: Map.update!(systems, name, &Map.put(&1, :deterministic_build, sibling))

  defp lines(systems, targets) do
    for {name, _} <- targets,
        %{deterministic_build: sibling} <- [systems[name]],
        do: "Deterministic sibling of #{name}: #{describe(sibling)}"
  end

  defp describe(%{status: "pass"}), do: "pass"
  defp describe(%{status: status, reason: reason}), do: "#{status} (#{reason})"

  defp manifest(%{"footprint" => %{"file_manifest" => %{} = manifest}}),
    do: %{"ebin" => entries(manifest, "ebin"), "priv" => entries(manifest, "priv")}

  defp manifest(_scan), do: nil

  defp entries(manifest, key) when is_map(manifest) do
    case manifest[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp entries(_manifest, _key), do: []

  defp ebin_entries(manifest), do: entries(manifest, "ebin")

  defp hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The target's own log under the worker's output mount.
  # sobelow_skip ["Traversal.FileModule"]
  defp append_log(log_file, line) do
    File.mkdir_p(Path.dirname(log_file))
    File.write(log_file, line <> "\n", [:append])
  end

  @doc false
  @spec default_runners() :: runners()
  def default_runners do
    %{
      compile: &OptionalDepsTargets.bounded_compile/4,
      scan: &scan/1,
      judge: &FirmwareBuildRoot.judge/4,
      reap: &OptionalDepsTargets.reap_writers/1,
      now: fn -> System.monotonic_time(:second) end
    }
  end

  defp scan(app_dir) do
    case BeamScan.analyze_app_dir(app_dir) do
      {:ok, scan} -> {:ok, scan}
      {:error, _} = error -> error
    end
  end
end
