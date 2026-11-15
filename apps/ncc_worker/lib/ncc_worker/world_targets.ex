defmodule NccWorker.WorldTargets do
  @moduledoc """
  The firmware world sub-pass (`NCC_INPUT.firmware_world`): a third build
  of the package per passing firmware target, beside the build with its
  optional dependencies and the one without (`NccWorker.OptionalDepsTargets`).

  It is the package compiled with, at every depth of its closure, each
  unresolved optional dependency that a fresh `mix nerves.new` app has in
  its prod env (`Compatibility.Worlds.firmware_members/1`, sent by the
  portal), resolved by the same fixpoint as a toolchain world build
  (`NccWorker.WorldDeps.resolve/4`). nerves_motd gets muontrap and
  nerves_time, not nerves_time_zones; a package whose closure has an
  optional edge to jason gets jason, which nerves 1.x brings into every
  default app.

  It runs after the optional pass, when every status, the build with and
  the build without are settled and `mix.exs`/`mix.lock` are restored, and
  it changes none of them. Each kept target gains a `published_variants`
  entry `"world_<name>"`, its files under
  `_build/<target>/lib/.<package>.world_<name>`.

  In order (see `run/2`):

    1. Nothing when the run is past 75 minutes, the pass's budget is spent,
       no target passed, or no world member is reachable from the lock
       (`WorldDeps.first_round/3`): then the world closure is the one the
       project has, and nothing is copied or compiled.
    2. `mix.exs` and `mix.lock` snapshotted; each passing target's
       published build (`_build/<t>/lib/<package>`) has its `priv`/`include`
       links made its own (`OptionalDepsTargets.own_links/1`), so nothing
       written through `deps_<t>` reaches it.
    3. `_build/<t>/lib` copied (`cp -a`) to `_build/<t>.world/lib`, without
       any `.<package>.*` dir. Everything below builds under
       `MIX_BUILD_PATH=_build/<t>.world` and nothing under `_build/<t>`.
    4. The fixpoint once, in the first target's world env. Its closure is
       Hex packages only, so it holds for every target. The world closure
       equal to the build without's (the run lock) stops it
       ("same_closure_as_without"), as does a lock entry it added outside
       the closure ("world_extra_deps"); a target whose build with has the
       same closure is dropped ("same_closure_as_with").
    5. In every remaining target's world build path, the package and every
       lock entry whose closure the fixpoint changed are removed
       (`DepsLock.changed_closures/2`): Mix does not rebuild ecto because
       jason appeared, and the package would expand ecto's macros as
       built without it. So is every dependency the build with may have
       compiled with an optional dependency the world lacks
       (`DepsLock.built_with_unresolved/2`): the copy holds the build path
       as that pass left it, and Mix rebuilds nothing when one goes away.
    6. Serially, per other target: `mix deps.get` into its own deps path,
       the lock policy, and the lock byte-equal to the fixpoint's
       ("world_lock_moved" otherwise).
    7. Concurrently: `mix compile`, the beam scan and the compile_env.
    8. A kept target's build is owned, renamed to its variant dir and
       checked against its scan (`OptionalDepsTargets.verify_files/2`).
    9. Every passing target's published build, and its build without, are
       checked again against what they recorded. A mismatch means this
       pass touched a published build: `{:error,
       {:optional_deps_revert_failed, _}}`, a retried run.
    10. The world build paths removed and the snapshot restored; a restore
        that fails is the same error.

  Anything else drops the world for the targets it concerns, logged in the
  target's log, with one of the reasons "deps_get_failed",
  "lock_policy_violation", "world_not_converged", "world_extra_deps",
  "world_lock_moved", "target_compile_failed", "timeout", "copy_failed",
  "files_changed", "same_closure_as_with", "same_closure_as_without",
  "deps_lock_unreadable", "mix_exs_edit_failed", "stale_build_not_removed",
  "run_budget_exhausted" or "no_passing_target".

  Every `mix`, Hex or copy step goes through a runner
  (`OptionalDepsTargets.default_runners/0`, plus `copy`), so tests stay
  offline.
  """

  alias NccWorker.{DepsLock, OptionalDepsTargets, Project, WorldDeps}

  @run_budget_sec 75 * 60
  @kill_grace_sec 60
  @app_name ~r/\A[a-z][a-z0-9_]*\z/

  @type params :: %{
          required(:project_dir) => String.t(),
          required(:package) => String.t(),
          required(:world) => %{name: String.t(), members: [String.t()]},
          # After the optional pass.
          required(:systems) => %{String.t() => map()},
          required(:targets) => [OptionalDepsTargets.target()],
          required(:timeout_sec) => pos_integer(),
          required(:concurrency) => pos_integer(),
          # The optional pass's deadline, in the `now` runner's seconds.
          required(:deadline) => integer(),
          # The run's lock, the build without's closure.
          required(:run_deps_lock) => DepsLock.t() | nil,
          optional(:run_elapsed_sec) => non_neg_integer()
        }

  @type summary :: %{
          name: String.t(),
          added: [String.t()],
          rounds: non_neg_integer(),
          kept: [String.t()],
          reason: String.t() | nil
        }

  @doc """
  Runs the sub-pass. `{:ok, %{systems: systems, world: summary}}`, the
  systems with each kept target's world variant appended to its
  `published_variants`, or `{:error, {:optional_deps_revert_failed, _}}`.
  """
  @spec run(params(), map()) ::
          {:ok, %{systems: map(), world: summary()}}
          | {:error, {:optional_deps_revert_failed, term()}}
  def run(params, runners \\ %{}) do
    r =
      OptionalDepsTargets.default_runners()
      |> Map.put(:copy, &copy_lib/2)
      |> Map.merge(runners)

    passing = passing_targets(params)

    cond do
      passing == [] ->
        done(params, [], "no_passing_target", nil)

      Map.get(params, :run_elapsed_sec, 0) > @run_budget_sec ->
        skip_all(params, passing, "run_budget_exhausted")

      params.deadline - r.now.() <= 0 ->
        skip_all(params, passing, "timeout")

      WorldDeps.first_round(params.project_dir, params.package, params.world.members) == [] ->
        skip_all(params, passing, "same_closure_as_without")

      true ->
        start(params, r, passing)
    end
  end

  defp passing_targets(%{systems: systems, targets: targets}),
    do: Enum.filter(targets, fn {name, _} -> match?(%{status: :pass}, systems[name]) end)

  defp skip_all(params, passing, reason) do
    Enum.each(passing, &log(&1, params, "not built (#{reason})"))
    done(params, [], reason, nil)
  end

  defp done(params, added, reason, rounds, kept \\ [], systems \\ nil) do
    {:ok,
     %{
       systems: systems || params.systems,
       world: %{
         name: params.world.name,
         added: added,
         rounds: rounds || 0,
         kept: kept,
         reason: if(kept == [], do: reason)
       }
     }}
  end

  defp start(params, r, passing) do
    with {:ok, snapshot} <- Project.snapshot(params.project_dir),
         {:ok, lock_before} <- DepsLock.lock(params.project_dir) do
      state = %{snapshot: snapshot, lock_before: lock_before, owned: [], copied: [], dropped: []}

      state
      |> own_published(params, passing)
      |> then(fn
        {:broken, reason, state} -> finish(params, r, state, {:error, reason})
        state -> state |> copy_all(params, r) |> fixpoint(params, r)
      end)
    else
      _ -> skip_all(params, passing, "deps_lock_unreadable")
    end
  end

  # Step 2.
  defp own_published(state, params, passing) do
    Enum.reduce_while(passing, state, fn target, state ->
      case OptionalDepsTargets.own_links(published(target, params)) do
        :ok -> {:cont, %{state | owned: state.owned ++ [target]}}
        {:error, _} -> {:cont, drop(state, target, "copy_failed")}
        {:broken, reason} -> {:halt, {:broken, reason, state}}
      end
    end)
  end

  # Step 3.
  defp copy_all(state, params, r) do
    Enum.reduce(state.owned, state, fn target, state ->
      case copy_target(target, params, r) do
        :ok -> %{state | copied: state.copied ++ [target]}
        :error -> drop(state, target, "copy_failed")
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_target({_name, %{env: env}}, params, r) do
    from = Path.join(build_path(env), "lib")
    world = world_path(env)
    to = Path.join(world, "lib")

    with {:ok, _} <- File.rm_rf(world),
         :ok <- File.mkdir_p(world),
         :ok <- r.copy.(from, to),
         {:ok, entries} <- File.ls(to),
         :ok <- remove_variants(to, entries, params.package) do
      :ok
    else
      _ -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_variants(lib, entries, package) do
    entries
    |> Enum.filter(&String.starts_with?(&1, ".#{package}."))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case File.rm_rf(Path.join(lib, entry)) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end

  # Step 4.
  defp fixpoint(%{copied: []} = state, params, r), do: finish(params, r, state, nil)

  defp fixpoint(%{copied: [first | _]} = state, params, r) do
    {_name, %{env: env, log_file: log_file}} = first
    env = world_env(env)

    deps_get = fn project_dir, fetch_env ->
      case time_left(params, r) do
        left when left > 0 ->
          r.deps_get.(project_dir, fetch_env, log_file, min(params.timeout_sec, left))

        _ ->
          {:error, :timeout}
      end
    end

    case WorldDeps.resolve(params.project_dir, params.package, params.world.members,
           env: env,
           deps_get: deps_get,
           outside_closure: false
         ) do
      {:ok, progress} ->
        state = Map.put(state, :progress, progress)
        closure(state, params, r)

      {:error, {:restore_failed, _reason, _cause} = reason} ->
        finish(params, r, state, {:error, reason})

      {:error, reason, _detail, progress} ->
        state
        |> Map.put(:progress, progress)
        |> drop_all(reason)
        |> then(&finish(params, r, &1, nil))
    end
  end

  defp closure(%{progress: %{added: []}} = state, params, r),
    do: state |> drop_all("same_closure_as_without") |> then(&finish(params, r, &1, nil))

  defp closure(state, params, r) do
    with {:lock, {:ok, lock_after}, %{} = world_lock} <-
           {:lock, DepsLock.lock(params.project_dir),
            DepsLock.read(params.project_dir, params.package)},
         {:run_lock, %{} = run_lock} <- {:run_lock, params.run_deps_lock},
         {:without, false} <- {:without, names(world_lock) == names(run_lock)},
         {:stray, []} <- {:stray, strays(state.lock_before, lock_after, world_lock)} do
      state = Map.merge(state, %{lock_after: lock_after, world_lock: world_lock})

      state
      |> drop_same_as_with(params, world_lock)
      |> remove_stale(params)
      |> fetch_others(params, r)
      |> compile_all(params, r)
    else
      {:lock, _, _} ->
        state |> drop_all("deps_lock_unreadable") |> then(&finish(params, r, &1, nil))

      {:run_lock, _} ->
        state |> drop_all("deps_lock_unreadable") |> then(&finish(params, r, &1, nil))

      {:without, true} ->
        state |> drop_all("same_closure_as_without") |> then(&finish(params, r, &1, nil))

      {:stray, _} ->
        state |> drop_all("world_extra_deps") |> then(&finish(params, r, &1, nil))
    end
  end

  defp drop_same_as_with(state, params, world_lock) do
    Enum.reduce(state.copied, state, fn {name, _} = target, state ->
      if same_as_with?(params.systems[name], world_lock),
        do: drop(state, target, "same_closure_as_with"),
        else: state
    end)
  end

  defp same_as_with?(%{deps_lock: %{} = with_lock}, world_lock),
    do: names(with_lock) == names(world_lock)

  defp same_as_with?(_system, _world_lock), do: false

  # Lock entries the fixpoint added that the package never reaches: they
  # would be loadable while it compiles. The template's own entries were
  # there before and are every Nerves app's.
  defp strays(before, after_lock, world_lock) do
    reach = MapSet.new(Map.keys(world_lock))

    after_lock
    |> Map.keys()
    |> Enum.reject(&(Map.has_key?(before, &1) or MapSet.member?(reach, &1)))
    |> Enum.sort()
  end

  defp names(lock), do: lock |> Map.keys() |> Enum.sort()

  # Step 5. Besides the closures the fixpoint changed, every dependency
  # the optional pass's build with may have compiled with an optional
  # dependency the world does not add: the copy holds `_build/<t>/lib` as
  # that build left it, and the restored lock makes Mix rebuild none of
  # them. Such a dependency was only built with it on a target whose lib
  # holds its build.
  defp remove_stale(state, params) do
    changed = [params.package | DepsLock.changed_closures(state.lock_before, state.lock_after)]

    Enum.reduce(live(state), state, fn {_name, %{env: env}} = target, state ->
      with {:ok, built} <- built_with_absent(state.lock_after, world_path(env)),
           apps = (changed ++ built) |> Enum.uniq() |> Enum.filter(&Regex.match?(@app_name, &1)),
           true <- Enum.all?(apps, &removed?(world_path(env), &1)) do
        state
      else
        _ -> drop(state, target, "stale_build_not_removed")
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp built_with_absent(lock, world) do
    with {:ok, entries} <- File.ls(Path.join(world, "lib")),
         do: {:ok, DepsLock.built_with_unresolved(lock, entries)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp removed?(world, app), do: match?({:ok, _}, File.rm_rf(Path.join([world, "lib", app])))

  # Step 6. The first target's deps were fetched by the fixpoint.
  # sobelow_skip ["Traversal.FileModule"]
  defp fetch_others(%{copied: [fixpoint_target | _]} = state, params, r) do
    lock_bytes = File.read(Path.join(params.project_dir, "mix.lock"))

    state
    |> live()
    |> Enum.reject(&(&1 == fixpoint_target))
    |> Enum.reduce(state, fn target, state ->
      case fetch(target, params, r, lock_bytes) do
        :ok -> state
        {:dropped, reason} -> drop(state, target, reason)
      end
    end)
  end

  # Reads only the generated worker project's mix.lock.
  # sobelow_skip ["Traversal.FileModule"]
  defp fetch({_name, %{env: env, log_file: log_file}}, params, r, lock_bytes) do
    with {:time, left} when left > 0 <- {:time, time_left(params, r)},
         :ok <-
           r.deps_get.(
             params.project_dir,
             world_env(env),
             log_file,
             min(params.timeout_sec, left)
           ),
         {:policy, :ok} <- {:policy, r.lock_policy.(params.project_dir)},
         {:moved, false} <-
           {:moved, File.read(Path.join(params.project_dir, "mix.lock")) != lock_bytes} do
      :ok
    else
      {:time, _} -> {:dropped, "timeout"}
      {:error, :timeout} -> {:dropped, "timeout"}
      {:error, _} -> {:dropped, "deps_get_failed"}
      {:policy, _} -> {:dropped, "lock_policy_violation"}
      {:moved, true} -> {:dropped, "world_lock_moved"}
    end
  end

  # Step 7.
  defp compile_all(state, params, r) do
    targets = live(state)

    outcomes =
      targets
      |> Task.async_stream(&compile_target(&1, params, r),
        max_concurrency: params.concurrency,
        timeout: (params.timeout_sec + @kill_grace_sec) * 1000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(targets)
      |> Enum.map(fn
        {{:ok, outcome}, target} -> {target, outcome}
        {{:exit, :timeout}, target} -> {target, {:dropped, "timeout"}}
      end)

    state =
      Enum.reduce(outcomes, state, fn
        {target, {:dropped, reason}}, state -> drop(state, target, reason)
        {_target, {:built, _scan, _ce}}, state -> state
      end)

    built = for {target, {:built, scan, ce}} <- outcomes, do: {target, scan, ce}
    settle(state, params, r, built)
  end

  defp compile_target({_name, %{env: env, log_file: log_file}}, params, r) do
    env = world_env(env)
    build_path = world_path(env)

    safely(fn ->
      with {:time, left} when left > 0 <- {:time, time_left(params, r)},
           :ok <- r.compile.(params.project_dir, env, log_file, min(params.timeout_sec, left)),
           scan when is_map(scan) <- r.scan.(build_path, params.package),
           [] <- Map.get(scan, "errors", []),
           %{} <- manifest(scan),
           compile_env when is_list(compile_env) <- r.compile_env.(build_path, params.package) do
        {:built, scan, compile_env}
      else
        {:time, _} -> {:dropped, "timeout"}
        {:error, :timeout} -> {:dropped, "timeout"}
        _ -> {:dropped, "target_compile_failed"}
      end
    end)
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:dropped, "target_compile_failed"}
  catch
    _, _ -> {:dropped, "target_compile_failed"}
  end

  defp manifest(%{"footprint" => %{"file_manifest" => %{"ebin" => ebin, "priv" => priv}}})
       when is_list(ebin) and is_list(priv) and (ebin != [] or priv != []),
       do: %{"ebin" => ebin, "priv" => priv}

  defp manifest(_scan), do: nil

  # Step 8. A dropped target's leftover writers are killed first: they
  # inherit its world build path.
  defp settle(state, params, r, built) do
    reaped =
      Enum.reduce_while(state.copied, :ok, fn {_name, %{env: env}}, :ok ->
        case r.reap.(world_path(world_env(env))) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case reaped do
      :ok ->
        {state, variants} = Enum.reduce(built, {state, %{}}, &keep_built(&1, &2, params))
        finish(params, r, Map.put(state, :variants, variants), nil)

      error ->
        finish(params, r, state, error)
    end
  end

  defp keep_built({{name, _} = target, scan, ce}, {state, acc}, params) do
    case keep(target, params, scan, ce, state.world_lock) do
      {:ok, variant} -> {state, Map.put(acc, name, variant)}
      {:error, reason} -> {drop(state, target, reason), acc}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp keep({_name, %{env: env}}, params, scan, compile_env, world_lock) do
    {:ok, variant_name} = variant_name(params)
    from = Path.join([world_path(world_env(env)), "lib", params.package])

    to =
      Path.join([
        build_path(env),
        "lib",
        OptionalDepsTargets.variant_dir(params.package, variant_name)
      ])

    manifest = manifest(scan)

    with {:own, :ok} <- {:own, OptionalDepsTargets.own_links(from)},
         {:rm, {:ok, _}} <- {:rm, File.rm_rf(to)},
         {:rename, :ok} <- {:rename, File.rename(from, to)},
         :ok <- OptionalDepsTargets.verify_files(to, manifest) do
      {:ok,
       %{
         variant: variant_name,
         beam_scan: %{"footprint" => %{"file_manifest" => manifest}},
         compile_env: compile_env,
         deps_lock: world_lock
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "copy_failed"}
    end
  end

  defp variant_name(params), do: Compatibility.Worlds.firmware_variant(params.world.name)

  # Steps 9 and 10.
  defp finish(params, _r, state, error) do
    variants = Map.get(state, :variants, %{})
    progress = Map.get(state, :progress, %{added: [], rounds: 0})

    checked = post_check(params, state.owned)
    # Every target a copy was started for, a failed one included.
    Enum.each(state.owned, &remove_world/1)
    restored = Project.restore(state.snapshot)

    case Enum.find([error, checked, restored], &(&1 not in [nil, :ok])) do
      nil ->
        Enum.each(state.dropped, fn {target, reason} ->
          log(target, params, "dropped (#{reason})")
        end)

        Enum.each(variants, fn {name, _} ->
          target = List.keyfind(params.targets, name, 0)
          log(target, params, "kept: #{Enum.join(progress.added, ", ")}")
        end)

        systems =
          Enum.reduce(variants, params.systems, fn {name, variant}, systems ->
            Map.update!(systems, name, &append_variant(&1, variant))
          end)

        reason =
          case state.dropped do
            [{_target, reason} | _] -> reason
            [] -> nil
          end

        kept =
          params.targets |> Enum.map(&elem(&1, 0)) |> Enum.filter(&Map.has_key?(variants, &1))

        done(params, progress.added, reason, progress.rounds, kept, systems)

      {:error, reason} ->
        {:error, {:optional_deps_revert_failed, reason}}
    end
  end

  defp append_variant(system, variant),
    do: Map.put(system, :published_variants, List.wrap(system[:published_variants]) ++ [variant])

  # Every build this pass owned the links of is checked again: the build
  # the target publishes, and its build without when it has one.
  defp post_check(params, owned) do
    Enum.find_value(owned, :ok, fn {name, _} = target ->
      system = params.systems[name]

      with :ok <- check(published(target, params), manifest(system[:beam_scan] || %{})),
           :ok <- check_without(target, params, system) do
        nil
      else
        {:error, reason} -> {:error, {:world_changed_published_build, name, reason}}
      end
    end)
  end

  defp check(_dir, nil), do: :ok
  defp check(dir, manifest), do: OptionalDepsTargets.verify_files(dir, manifest)

  defp check_without({_name, %{env: env}}, params, system) do
    case Enum.find(List.wrap(system[:published_variants]), &(&1[:variant] == "without")) do
      nil ->
        :ok

      variant ->
        dir = Path.join([build_path(env), "lib", OptionalDepsTargets.variant_dir(params.package)])
        check(dir, manifest(variant.beam_scan))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_world({_name, %{env: env, log_file: log_file}}) do
    case File.rm_rf(world_path(world_env(env))) do
      {:ok, _} -> :ok
      {:error, reason, path} -> append_log(log_file, "==> could not remove #{path}: #{reason}")
    end
  end

  defp drop(state, target, reason) do
    if List.keymember?(state.dropped, target, 0),
      do: state,
      else: %{state | dropped: state.dropped ++ [{target, reason}]}
  end

  defp drop_all(state, reason), do: Enum.reduce(live(state), state, &drop(&2, &1, reason))

  defp live(state), do: Enum.reject(state.copied, &List.keymember?(state.dropped, &1, 0))

  defp time_left(params, r), do: params.deadline - r.now.()

  defp published({_name, %{env: env}}, params),
    do: Path.join([build_path(env), "lib", params.package])

  defp build_path(env) do
    {_, path} = List.keyfind(env, "MIX_BUILD_PATH", 0)
    path
  end

  # The world build path of a target's env, or of a world env itself.
  defp world_path(env) do
    path = build_path(env)
    if String.ends_with?(path, ".world"), do: path, else: path <> ".world"
  end

  defp world_env(env),
    do: List.keystore(env, "MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", world_path(env)})

  defp log(nil, _params, _line), do: :ok

  defp log({_name, %{log_file: log_file}}, params, line),
    do: append_log(log_file, "==> world #{params.world.name}: #{line}")

  # sobelow_skip ["Traversal.FileModule"]
  defp append_log(log_file, line) do
    File.mkdir_p(Path.dirname(log_file))
    File.write(log_file, line <> "\n", [:append])
  end

  # `cp -a`, so the copy keeps the timestamps Mix's staleness checks read,
  # and the relative `priv` links of every dependency, which resolve the
  # same from `_build/<t>.world/lib` (the same depth).
  # Literal arguments, worker-generated paths, no shell.
  # sobelow_skip ["CI.System"]
  defp copy_lib(from, to) do
    case System.cmd("cp", ["-a", from, to], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {code, output}}
    end
  end
end
