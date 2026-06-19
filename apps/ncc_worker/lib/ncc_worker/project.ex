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
    - package: Package information map
    - systems_override: Optional map of system package names to version requirements

  ## Returns
    - {:ok, project_dir} - Path to the created project
    - {:error, reason} - Creation failed
  """
  @spec create(String.t(), map(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def create(work_dir, package, systems_override \\ nil) do
    project_dir = Path.join(work_dir, "proj")

    with :ok <- create_nerves_project(project_dir, package.name),
         :ok <- maybe_apply_systems_override(project_dir, systems_override) do
      {:ok, project_dir}
    end
  end

  @doc """
  Adds the target package to the project by editing mix.exs and running
  `mix deps.get`.

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
  @spec add_package(String.t(), map()) :: {:ok, :added} | {:error, term()}
  def add_package(project_dir, package) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, new_content} <- inject_dep(content, package),
         :ok <- File.write(mix_exs_path, new_content),
         :ok <- run_deps_get(project_dir) do
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

  @spec run_deps_get(String.t()) :: :ok | {:error, term()}
  defp run_deps_get(project_dir) do
    case System.cmd("mix", ["deps.get"], cd: project_dir, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, {:deps_get_failed, error}}
    end
  end

  @spec create_nerves_project(String.t(), String.t()) :: :ok | {:error, term()}
  defp create_nerves_project(project_dir, _package_name) do
    # Create the project directory
    File.mkdir_p!(project_dir)

    # Create the test project
    case System.cmd(
           "mix",
           ["nerves.new", ".", "--app", "nerves_compatibility_test", "--no-nerves-pack"],
           cd: project_dir,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {error, _} ->
        {:error, {:nerves_new_failed, error}}
    end
  end

  @spec maybe_apply_systems_override(String.t(), map() | nil) :: :ok | {:error, term()}
  defp maybe_apply_systems_override(_project_dir, nil), do: :ok

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
