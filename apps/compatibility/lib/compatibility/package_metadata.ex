defmodule Compatibility.PackageMetadata do
  @moduledoc """
  Loads and manages package-specific metadata.

  This module reads the package_metadata.json file which contains:
  - forced_status: Administrative override for test status
  - notes: User-facing information about the package
  - allowed_systems: Whitelist of systems to test (empty means all)
  - denied_systems: Blacklist of systems to exclude from testing
  - skip_if_depends_on: Global list of dependencies that cause packages to be skipped
  """

  @type status :: :pass | :fail | :skip
  @type metadata :: %{
          forced_status: status() | nil,
          notes: String.t() | nil,
          allowed_systems: [String.t()],
          denied_systems: [String.t()]
        }

  @type t :: %__MODULE__{
          packages: %{String.t() => metadata()},
          skip_if_depends_on: [String.t()]
        }

  defstruct packages: %{}, skip_if_depends_on: []

  @doc """
  Load package metadata from a JSON file.

  ## Examples

      iex> Compatibility.PackageMetadata.load("package_metadata.json")
      {:ok, %Compatibility.PackageMetadata{packages: %{...}}}

      iex> Compatibility.PackageMetadata.load("missing.json")
      {:error, :enoent}
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content),
         {:ok, metadata} <- parse(data) do
      {:ok, metadata}
    else
      {:error, :enoent} ->
        # If file doesn't exist, return empty metadata
        {:ok, %__MODULE__{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get metadata for a specific package.

  Returns default empty metadata if package is not found.

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{packages: %{"jason" => %{notes: "Test"}}}
      iex> Compatibility.PackageMetadata.get(metadata, "jason")
      %{forced_status: nil, notes: "Test", allowed_systems: [], denied_systems: []}

      iex> metadata = %Compatibility.PackageMetadata{packages: %{}}
      iex> Compatibility.PackageMetadata.get(metadata, "unknown")
      %{forced_status: nil, notes: nil, allowed_systems: [], denied_systems: []}
  """
  @spec get(t(), String.t()) :: metadata()
  def get(%__MODULE__{packages: packages}, package_name) do
    Map.get(packages, package_name, default_metadata())
  end

  @doc """
  Check if a package has a forced status.

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{packages: %{"jason" => %{forced_status: :skip}}}
      iex> Compatibility.PackageMetadata.forced_status(metadata, "jason")
      {:forced, :skip}

      iex> metadata = %Compatibility.PackageMetadata{packages: %{}}
      iex> Compatibility.PackageMetadata.forced_status(metadata, "jason")
      :none
  """
  @spec forced_status(t(), String.t()) :: {:forced, status()} | :none
  def forced_status(metadata, package_name) do
    case get(metadata, package_name) do
      %{forced_status: status} when status in [:pass, :fail, :skip] ->
        {:forced, status}

      _ ->
        :none
    end
  end

  @doc """
  Check if a system is allowed for a package.

  Returns true if:
  - No allowed_systems list is specified (empty list means all allowed)
  - The system is in the allowed_systems list
  - The system is NOT in the denied_systems list

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{
      ...>   packages: %{
      ...>     "wifi_pkg" => %{
      ...>       allowed_systems: [],
      ...>       denied_systems: ["nerves_system_grisp2"]
      ...>     }
      ...>   }
      ...> }
      iex> Compatibility.PackageMetadata.system_allowed?(metadata, "wifi_pkg", "nerves_system_rpi4")
      true
      iex> Compatibility.PackageMetadata.system_allowed?(metadata, "wifi_pkg", "nerves_system_grisp2")
      false
  """
  @spec system_allowed?(t(), String.t(), String.t()) :: boolean()
  def system_allowed?(metadata, package_name, system_name) do
    pkg_meta = get(metadata, package_name)
    allowed = pkg_meta.allowed_systems
    denied = pkg_meta.denied_systems

    # Check denied list first
    cond do
      system_name in denied ->
        false

      # If allowed list is empty, all systems are allowed (except denied)
      allowed == [] ->
        true

      # If allowed list exists, system must be in it
      true ->
        system_name in allowed
    end
  end

  @doc """
  Filter a list of systems based on package metadata.

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{
      ...>   packages: %{
      ...>     "pkg" => %{
      ...>       allowed_systems: [],
      ...>       denied_systems: ["nerves_system_grisp2"]
      ...>     }
      ...>   }
      ...> }
      iex> systems = ["nerves_system_rpi4", "nerves_system_grisp2"]
      iex> Compatibility.PackageMetadata.filter_systems(metadata, "pkg", systems)
      ["nerves_system_rpi4"]
  """
  @spec filter_systems(t(), String.t(), [String.t()]) :: [String.t()]
  def filter_systems(metadata, package_name, systems) do
    Enum.filter(systems, &system_allowed?(metadata, package_name, &1))
  end

  @doc """
  Check if a package should be skipped based on its dependencies.

  Returns true if any of the package's dependencies are in the skip_if_depends_on list.

  ## Parameters

    - metadata: PackageMetadata struct
    - dependencies: List of dependency names (strings)

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{skip_if_depends_on: ["nerves_system_br"]}
      iex> Compatibility.PackageMetadata.should_skip_by_dependency?(metadata, ["nerves_system_br", "jason"])
      true

      iex> metadata = %Compatibility.PackageMetadata{skip_if_depends_on: ["nerves_system_br"]}
      iex> Compatibility.PackageMetadata.should_skip_by_dependency?(metadata, ["jason", "ecto"])
      false
  """
  @spec should_skip_by_dependency?(t(), [String.t()]) :: boolean()
  def should_skip_by_dependency?(%__MODULE__{skip_if_depends_on: skip_list}, dependencies) do
    skip_set = MapSet.new(skip_list)
    dep_set = MapSet.new(dependencies)

    not MapSet.disjoint?(skip_set, dep_set)
  end

  @doc """
  Get the list of dependencies that should trigger skipping.

  ## Examples

      iex> metadata = %Compatibility.PackageMetadata{skip_if_depends_on: ["nerves_system_br"]}
      iex> Compatibility.PackageMetadata.get_skip_dependencies(metadata)
      ["nerves_system_br"]
  """
  @spec get_skip_dependencies(t()) :: [String.t()]
  def get_skip_dependencies(%__MODULE__{skip_if_depends_on: skip_list}) do
    skip_list
  end

  ## Private Functions

  defp parse(data) when is_map(data) do
    packages =
      case data["packages"] do
        packages when is_map(packages) ->
          packages
          |> Enum.reject(fn {key, _} -> String.starts_with?(key, "_") end)
          |> Enum.map(fn {name, meta} -> {name, parse_package_metadata(meta)} end)
          |> Map.new()

        _ ->
          %{}
      end

    skip_if_depends_on = data["skip_if_depends_on"] || []

    {:ok, %__MODULE__{packages: packages, skip_if_depends_on: skip_if_depends_on}}
  end

  defp parse(_) do
    # If data is invalid, return empty metadata
    {:ok, %__MODULE__{}}
  end

  defp parse_package_metadata(meta) when is_map(meta) do
    %{
      forced_status: parse_status(meta["forced_status"]),
      notes: meta["notes"],
      allowed_systems: meta["allowed_systems"] || [],
      denied_systems: meta["denied_systems"] || []
    }
  end

  defp parse_status("pass"), do: :pass
  defp parse_status("fail"), do: :fail
  defp parse_status("skip"), do: :skip
  defp parse_status(_), do: nil

  defp default_metadata() do
    %{
      forced_status: nil,
      notes: nil,
      allowed_systems: [],
      denied_systems: []
    }
  end
end
