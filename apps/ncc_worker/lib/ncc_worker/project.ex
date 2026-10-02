defmodule NccWorker.Project do
  @moduledoc """
  Creates and configures Nerves projects for testing packages.

  Handles:
  - Creating a new Nerves project non-interactively
  - Adding package dependencies
  - Applying system version overrides
  """

  @doc """
  Creates a new Nerves project in the specified work directory.

  ## Parameters
    - work_dir: Base working directory
    - systems_override: Optional map of system package names to version requirements
    - targets: Nerves target names to generate system deps for, from
      `NccWorker.Systems.targets/1`

  ## Returns
    - {:ok, project_dir} - Path to the created project
    - {:error, reason} - Creation failed
  """
  # Workaround until `mix nerves.new` can generate a project on a Nerves
  # prerelease: the archive template emits a stable `~> 1.x` requirement, and Hex
  # never picks a prerelease for a requirement that does not name one. Every
  # system we build already accepts `~> 2.0.0-dev`, so the systems stay as
  # generated. The template is also a Nerves 1 project, so it gets the migration
  # `Nerves.Release` documents: Nerves 2 does Shoehorn's app ordering itself.
  # Drop this, `migrate_to_nerves_2/1` and its helpers once nerves.new grows the
  # flag.
  @nerves_requirement "== 2.0.0-pre.2"

  # Nerves 2 refuses to build a target whose plan lacks TARGET_CPU, and
  # nerves_system_x86_64 (1.34.2 and main) never declared one -- every other
  # system we build does. The project's own `:nerves` env is merged into the
  # same plan, so it can fill the gap. The value follows the other systems'
  # convention of the gcc CPU name with `-` as `_`; x86_64 builds with
  # `-march=x86-64`. Drop once the system declares it.
  @x86_64_target_cpu ~S|nerves: if(Mix.target() == :x86_64, do: [env: [{"TARGET_CPU", "x86_64"}]], else: []),|

  @spec create(String.t(), map() | nil, [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def create(work_dir, systems_override, targets) do
    project_dir = Path.join(work_dir, "proj")

    with :ok <- create_nerves_project(project_dir, targets),
         :ok <- migrate_to_nerves_2(project_dir),
         :ok <- maybe_apply_systems_override(project_dir, systems_override) do
      {:ok, project_dir}
    end
  end

  @doc """
  Adds the target package to the project by editing mix.exs and running
  `mix deps.get`.

  `env` is not optional on purpose. nerves_bootstrap hooks `deps.get` and
  compiles the whole dependency tree there, because it has to load every dep to
  resolve Nerves artifacts. With no env that compile runs in `MIX_ENV=dev` into
  `_build/dev`, which nothing downstream ever reads: the host build uses
  `_build/host` in `:prod` and each target its own `_build/<target>`. Measured on
  a project with `ash` as its only dep, that threw away 393 seconds and 2106
  beam files per run. Handing in the host build's env makes the same compile
  land where the host stage will pick it up.

  Note: we deliberately avoid `mix igniter.install`. That command temporarily
  injects igniter into mix.exs with `only: [:dev, :test]`, which fails with
  "Dependencies have diverged" whenever the target package depends on igniter
  as a regular (non-:only) dep — a very common pattern in modern Phoenix/Ash
  packages. Of 22 worker crashes in an overnight run, every single one was
  this conflict. For compat testing we only need the package to be in mix.exs
  and fetchable; igniter's install-time code generators aren't required to
  answer "does this package compile on Nerves?".

  ## Parameters
    - project_dir: Path to the project directory
    - package: Package information with name and optional version/requirement

  ## Returns
    - {:ok, :added} - Package was added successfully
    - {:error, reason} - Failed to add package
  """
  @spec add_package(String.t(), map(), keyword() | list()) :: {:ok, :added} | {:error, term()}
  # Edits only the generated worker project mix.exs; the worker deliberately builds package code.
  # sobelow_skip ["Traversal.FileModule"]
  def add_package(project_dir, package, env) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, new_content} <- inject_dep(content, package),
         :ok <- File.write(mix_exs_path, new_content),
         :ok <- run_deps_get(project_dir, env) do
      {:ok, :added}
    end
  end

  @spec inject_dep(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defp inject_dep(content, package) do
    dep_line = "      #{dep_tuple(package)},\n"

    # Insert the new dep as the first entry in the `defp deps do [...] end`
    # block. The anchor is the opening "[" of the deps list — matching there
    # survives variations in spacing and subsequent dep layout.
    case Regex.run(~r/defp\s+deps\s+do\s*\n\s*\[\s*\n/, content, return: :index) do
      [{start, len}] ->
        {before, rest} = String.split_at(content, start + len)
        {:ok, before <> dep_line <> rest}

      _ ->
        {:error, {:mix_exs_deps_list_not_found, content}}
    end
  end

  @spec dep_tuple(map()) :: String.t()
  defp dep_tuple(%{name: name, version: version}) when is_binary(version) and version != "",
    do: ~s[{:#{name}, "== #{version}"}]

  defp dep_tuple(%{name: name, requirement: req}) when is_binary(req) and req != "",
    do: ~s[{:#{name}, "#{req}"}]

  defp dep_tuple(%{name: name}),
    do: ~s[{:#{name}, ">= 0.0.0"}]

  @spec run_deps_get(String.t(), list()) :: :ok | {:error, term()}
  defp run_deps_get(project_dir, env) do
    case System.cmd("mix", ["deps.get"], cd: project_dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, {:deps_get_failed, error}}
    end
  end

  @spec create_nerves_project(String.t(), [String.t()]) :: :ok | {:error, term()}
  # project_dir is the runner-configured work mount plus the fixed proj directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_nerves_project(project_dir, targets) do
    # Create the project directory
    File.mkdir_p!(project_dir)

    # Targets are named explicitly. Called bare, `mix nerves.new` falls back to
    # nerves_bootstrap's own `@default_targets` -- eleven systems, only three of
    # which we build, and which omits trellis entirely. A system missing from
    # mix.exs does not fail visibly; it fails that target on every package with
    # an unresolvable dependency, which reads like the package being broken.
    # Create the test project
    case System.cmd("mix", nerves_new_args(targets), cd: project_dir, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, _} ->
        {:error, {:nerves_new_failed, error}}
    end
  end

  @spec maybe_apply_systems_override(String.t(), map() | nil) :: :ok | {:error, term()}
  defp maybe_apply_systems_override(_project_dir, nil), do: :ok

  # Edits the fixed mix.exs in the generated container project; overrides are operator inputs.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_apply_systems_override(project_dir, systems_override)
       when is_map(systems_override) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    case File.read(mix_exs_path) do
      {:ok, content} ->
        updated_content = apply_overrides(content, systems_override)
        File.write(mix_exs_path, updated_content)

      {:error, reason} ->
        {:error, {:cannot_read_mix_exs, reason}}
    end
  end

  # Edits the fixed mix.exs and config in the generated container project.
  # sobelow_skip ["Traversal.FileModule"]
  @spec migrate_to_nerves_2(String.t()) :: :ok | {:error, term()}
  defp migrate_to_nerves_2(project_dir) do
    mix_exs_path = Path.join(project_dir, "mix.exs")
    target_config_path = Path.join([project_dir, "config", "target.exs"])

    with {:ok, mix_exs} <- File.read(mix_exs_path),
         {:ok, migrated} <- nerves_2_mix_exs(mix_exs),
         :ok <- File.write(mix_exs_path, migrated),
         {:ok, target_config} <- File.read(target_config_path) do
      File.write(target_config_path, nerves_2_target_config(target_config))
    end
  end

  @doc false
  # Fails rather than passing through when the `:nerves` dep or the project's
  # `app:` line is missing: a template change that moved either would otherwise
  # silently put every build back on stable Nerves, or every x86_64 build into
  # a missing-TARGET_CPU failure. The release hooks only matter for tidiness --
  # Nerves 2 still accepts the 1.x ones with a deprecation warning.
  @spec nerves_2_mix_exs(String.t()) :: {:ok, String.t()} | {:error, term()}
  def nerves_2_mix_exs(content) do
    nerves_dep = ~r/(\{:nerves\s*,\s*)"[^"]*"/
    project_app = ~r/^([ \t]*)app: @app,\n/m

    if Regex.match?(nerves_dep, content) and Regex.match?(project_app, content) do
      {:ok,
       content
       |> String.replace(nerves_dep, "\\1\"#{@nerves_requirement}\"")
       |> String.replace(project_app, "\\0\\1#{@x86_64_target_cpu}\n", global: false)
       |> String.replace(~r/^\s*\{:shoehorn\s*,[^}]*\},?\n/m, "")
       |> String.replace("&Nerves.Release.erts/0", "&Nerves.erts/0")
       |> String.replace("&Nerves.Release.init/1", "&Nerves.init_release/1")}
    else
      {:error, {:nerves_2_migration_failed, content}}
    end
  end

  @doc false
  # With `:shoehorn` gone from the deps, its config would otherwise point at an
  # app that is not there. The start order moves over unchanged.
  @spec nerves_2_target_config(String.t()) :: String.t()
  def nerves_2_target_config(content) do
    String.replace(
      content,
      ~r/config :shoehorn,\s*init:\s*(\[[^\]]*\])/,
      "config :nerves, application_sort: [init: \\1]"
    )
  end

  @doc false
  @spec nerves_new_args([String.t()]) :: [String.t()]
  def nerves_new_args(targets) do
    ["nerves.new", ".", "--app", "nerves_compatibility_test", "--no-nerves-pack"] ++
      Enum.flat_map(targets, &["--target", &1])
  end

  @spec apply_overrides(String.t(), map()) :: String.t()
  defp apply_overrides(content, systems_override) do
    Enum.reduce(systems_override, content, fn {system_pkg, requirement}, acc ->
      # Replace the version requirement for this system package
      # Pattern: {:nerves_system_xxx, "~> x.y.z", runtime: false, targets: :xxx}
      pattern = ~r/(:\s*#{Regex.escape(system_pkg)}\s*,\s*)"[^"]*"/

      String.replace(acc, pattern, "\\1\"#{requirement}\"")
    end)
  end
end
