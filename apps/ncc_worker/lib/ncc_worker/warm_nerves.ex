defmodule NccWorker.WarmNerves do
  @moduledoc """
  A `mode: "warm_nerves"` run: fills the shared Nerves cache with trusted code
  only (isolation spec, section 1).

  The container mounts `/nerves-cache` read-write and runs nothing but the
  generated template project and the Nerves packages the host allowed
  (`Portal.NervesCache.warm_pairs/2`). `NccWorker.NervesCache` has already
  pointed Nerves at `/nerves-cache/staging/<run_id>`, a farm over the cache.

  `plan/2` pins each requested system exactly (`"== version"`, through
  `NccWorker.Project`'s `systems_override`) and never a toolchain, which only
  resolves through its system. Each target then runs `mix deps.get` and
  `mix nerves.artifact.get`: Nerves 2.0.0-pre.3 resolves artifacts in
  `Nerves.export_env/0`, which `nerves.artifact.get` runs before halting.
  Running a dependency's task goes through `deps.loadpaths`, which compiles
  the template's dependencies first, so the warm executes the generated
  template's Hex dependencies (what `mix nerves.new` generates: nerves, the
  runtime libraries, the systems and their toolchains, and everything they
  depend on), not only nerves-owned packages. That is why the template is the trusted, generated
  one and never a package's project. When every target succeeded,
  `NervesCache.install_staged/1` renames what was extracted into the cache;
  if any failed, nothing is installed and the run fails (exit 10, retried).
  The staging dir goes either way.

  The result's `warm.resolved` lists the project's locked Nerves systems and
  toolchains as `<name>-<version>`: for a run with no pairs, the versions the
  template currently resolves, which the host keeps out of eviction.
  """

  alias NccWorker.{Argus, NervesCache, Project, Systems}

  @pair_name ~r/\Anerves_(system|toolchain)_[a-z0-9_]+\z/

  @type plan :: %{
          requested: [NervesCache.pair()],
          overrides: %{String.t() => String.t()},
          systems: [Systems.t()],
          rejected: [term()]
        }

  @type warm :: %{
          requested: [NervesCache.pair()],
          rejected: [term()],
          targets: [String.t()],
          installed: [String.t()],
          kept: [String.t()],
          replaced: [String.t()],
          incomplete: [String.t()],
          resolved: [String.t()],
          not_warmed: [NervesCache.pair()]
        }

  @doc """
  What a warm of `pairs` does with `systems` (`NccWorker.Systems.default/0`):
  which systems to pin, which targets to resolve, and which pairs to refuse.
  A pair is a `%{"name", "version"}` whose name is `nerves_system_*` or
  `nerves_toolchain_*` and whose version parses as a version; anything else,
  a system this worker does not build, and a second version of one system are
  rejected. Targets are every system's when there are no pinned systems or any
  toolchain, else only the pinned systems'.
  """
  @spec plan(term(), [Systems.t()]) :: plan()
  def plan(pairs, systems) do
    {valid, invalid} = pairs |> List.wrap() |> Enum.split_with(&valid_pair?/1)
    by_name = Map.new(systems, &{&1.name, &1})

    {system_pairs, toolchains} =
      Enum.split_with(valid, &String.starts_with?(&1["name"], "nerves_system_"))

    {known, unknown} = Enum.split_with(system_pairs, &Map.has_key?(by_name, &1["name"]))
    pinned = Enum.uniq_by(known, & &1["name"])
    pinned_names = MapSet.new(pinned, & &1["name"])

    targets =
      if pinned == [] or toolchains != [],
        do: systems,
        else: Enum.filter(systems, &MapSet.member?(pinned_names, &1.name))

    %{
      requested: pinned ++ toolchains,
      overrides: Map.new(pinned, &{&1["name"], "== " <> &1["version"]}),
      systems: targets,
      rejected: invalid ++ unknown ++ (known -- pinned)
    }
  end

  defp valid_pair?(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version) and byte_size(version) <= 64,
       do: Regex.match?(@pair_name, name) and match?({:ok, _}, Version.parse(version))

  defp valid_pair?(_pair), do: false

  @doc """
  Runs the warm described by `input.nerves_packages` into `layout` (a
  `:staging` layout from `NccWorker.NervesCache.prepare/2`). `opts[:create_project]`,
  `opts[:mix]` and `opts[:put_env]` replace `Project.create/3`, the `mix` runner
  and `System.put_env/2` in tests.

  Every `mix` the warm spawns, `Project.create/3`'s included, resolves through
  a fresh, empty `HEX_HOME` at `<work_dir>/hex-home`, never the shared
  `/hex-cache`: every build mounts that read-write and could plant a
  `hex.config`, registry cache or tarball there for the one container that
  writes the Nerves cache to fetch and run.
  """
  @spec run(map(), map(), map(), NervesCache.layout(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(input, paths, toolchain, layout, opts \\ []) do
    plan = plan(input[:nerves_packages], Systems.default())
    create = Keyword.get(opts, :create_project, &Project.create/3)
    mix = Keyword.get(opts, :mix, &run_mix/4)
    put_env = Keyword.get(opts, :put_env, &System.put_env/2)
    log_file = Path.join([paths.output_dir, "logs", "warm_nerves.log"])

    try do
      hex_home = fresh_hex_home(paths.work_dir)
      :ok = put_env.("HEX_HOME", hex_home)

      with {:ok, project_dir} <-
             create.(paths.work_dir, overrides(plan), Systems.targets(Systems.default())),
           :ok <- resolve(project_dir, plan.systems, mix, log_file, hex_home),
           {:ok, installed} <- NervesCache.install_staged(layout) do
        resolved =
          project_dir |> NervesCache.lock_entries() |> Enum.map(&NervesCache.entry_name/1)

        {:ok, result(input, toolchain, plan, installed, resolved)}
      end
    after
      NervesCache.cleanup(layout)
    end
  end

  defp overrides(%{overrides: overrides}) when map_size(overrides) == 0, do: nil
  defp overrides(%{overrides: overrides}), do: overrides

  # work_dir is the worker's /work mount; the name is fixed.
  # sobelow_skip ["Traversal.FileModule"]
  defp fresh_hex_home(work_dir) do
    dir = Path.join(work_dir, "hex-home")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp resolve(project_dir, systems, mix, log_file, hex_home) do
    Enum.reduce_while(systems, :ok, fn system, :ok ->
      env = [
        {"HEX_HOME", hex_home},
        {"MIX_TARGET", system.target},
        {"MIX_ENV", "prod"},
        {"MIX_BUILD_PATH", Path.join([project_dir, "_build", system.target])},
        {"MIX_DEPS_PATH", Path.join(project_dir, "deps_#{system.target}")}
      ]

      with :ok <- step(mix, ["deps.get"], project_dir, env, log_file, system),
           :ok <- step(mix, ["nerves.artifact.get"], project_dir, env, log_file, system) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp step(mix, args, project_dir, env, log_file, system) do
    case mix.(args, project_dir, env, log_file) do
      :ok -> :ok
      {:error, code} -> {:error, {:warm_failed, system.name, Enum.join(args, " "), code}}
    end
  end

  # Literal mix tasks in the generated project; log_file is under the /out mount.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp run_mix(args, project_dir, env, log_file) do
    case System.cmd("mix", args,
           cd: project_dir,
           env: env,
           stderr_to_stdout: true,
           into: File.stream!(log_file, [:append])
         ) do
      {_, 0} -> :ok
      {_, code} -> {:error, code}
    end
  end

  defp result(input, toolchain, plan, installed, resolved) do
    resolved_set = MapSet.new(resolved)

    %{
      run_id: input.run_id,
      package: nil,
      image: input.image,
      toolchain: toolchain,
      systems: %{},
      argus: Argus.skipped(),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      scope: "warm_nerves",
      warm: %{
        requested: plan.requested,
        rejected: plan.rejected,
        targets: Enum.map(plan.systems, & &1.name),
        installed: installed.installed,
        kept: installed.kept,
        replaced: installed.replaced,
        incomplete: installed.incomplete,
        resolved: resolved,
        not_warmed:
          Enum.reject(plan.requested, &MapSet.member?(resolved_set, NervesCache.entry_name(&1)))
      }
    }
  end
end
