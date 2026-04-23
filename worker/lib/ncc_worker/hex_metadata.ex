defmodule NccWorker.HexMetadata do
  @moduledoc """
  Fetches package metadata from Hex.pm API.
  """

  @doc """
  Fetches package metadata including description, dependencies, and build tools
  from Hex.pm.

  ## Parameters
    - package_name: Name of the package on Hex.pm
    - version: Version of the package (if nil, fetches latest)

  ## Returns
    - {:ok, metadata} - Metadata fetched successfully
    - {:error, reason} - Failed to fetch metadata

  ## Metadata structure
    %{
      description: String.t(),
      dependencies: map() | nil,  # Release info to be parsed with parse_dependencies/2
      retired: map() | nil,
      release_version: String.t() | nil,
      build_tools: [String.t()]
    }
  """
  @spec fetch(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def fetch(package_name, version \\ nil) do
    # First, fetch the package info to get description
    package_url = "https://hex.pm/api/packages/#{package_name}"

    with {:ok, %{status: 200, body: pkg_body}} <- Req.get(package_url),
         description <- get_in(pkg_body, ["meta", "description"]) || "No description",
         github_url <- extract_github_url(pkg_body),
         # Then fetch the release info for dependencies
         {:ok, dependencies} <- fetch_dependencies(package_name, version) do
      {:ok,
       %{
         description: description,
         github_url: github_url,
         dependencies: dependencies,
         retired: normalize_retired(dependencies),
         release_version: release_version(dependencies),
         build_tools: extract_build_tools(dependencies)
       }}
    else
      {:ok, %{status: status}} ->
        {:error, {:hex_api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Hex packages ship a free-form `meta.links` map — keys are human labels
  # like "GitHub" / "Source" / "Docs" / "Homepage". Pick the first URL
  # whose host is github.com. Returns nil when none match.
  defp extract_github_url(pkg_body) do
    links = get_in(pkg_body, ["meta", "links"]) || %{}

    links
    |> Enum.find_value(fn
      {_label, url} when is_binary(url) ->
        if String.match?(url, ~r/^https?:\/\/(www\.)?github\.com\//), do: url

      _ ->
        nil
    end)
  end

  @spec fetch_dependencies(String.t(), String.t() | nil) :: {:ok, list()} | {:error, term()}
  defp fetch_dependencies(package_name, version) do
    # Use Hex API to fetch release info for dependencies
    url =
      if version do
        "https://hex.pm/api/packages/#{package_name}/releases/#{version}"
      else
        # Need to get the latest release version first
        "https://hex.pm/api/packages/#{package_name}"
      end

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        release_info =
          if version do
            body
          else
            # Get latest stable release from releases array
            releases = body["releases"] || []
            # Find the latest non-alpha/beta/rc release
            Enum.find(releases, List.first(releases), fn rel ->
              version = rel["version"]
              !String.contains?(version, ["-alpha", "-beta", "-rc"])
            end)
          end

        if release_info do
          # Return release info so caller can parse with runtime info
          {:ok, release_info}
        else
          {:ok, nil}
        end

      {:ok, %{status: status}} ->
        {:error, {:hex_api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp normalize_retired(nil), do: nil

  defp normalize_retired(release_info) when is_map(release_info) do
    Map.get(release_info, "retired") || Map.get(release_info, :retired)
  end

  defp normalize_retired(_), do: nil

  defp extract_build_tools(nil), do: []

  defp extract_build_tools(release_info) when is_map(release_info) do
    case release_info do
      %{"meta" => %{"build_tools" => tools}} when is_list(tools) -> tools
      %{meta: %{build_tools: tools}} when is_list(tools) -> tools
      _ -> []
    end
  end

  defp extract_build_tools(_), do: []

  defp release_version(nil), do: nil

  defp release_version(release_info) when is_map(release_info) do
    Map.get(release_info, "version") || Map.get(release_info, :version)
  end

  defp release_version(_), do: nil

  @doc """
  Parses dependencies from Hex release info and marks runtime dependencies.

  ## Parameters
    - release_info: Release information from Hex API
    - runtime_apps: List of application names (atoms or strings) that are runtime dependencies

  ## Returns
    List of dependency maps with runtime flag set based on runtime_apps
  """
  @spec parse_dependencies(map(), list()) :: list()
  def parse_dependencies(release_info, runtime_apps \\ []) do
    # Convert runtime_apps to strings for comparison
    runtime_app_names = Enum.map(runtime_apps, &to_string/1) |> MapSet.new()

    (release_info["requirements"] || %{})
    |> Enum.map(fn {name, req_info} ->
      # The dependency is runtime if it appears in the runtime_apps list
      # Use the "app" field from Hex if available, otherwise use the dependency name
      app_name = req_info["app"] || name
      is_runtime = MapSet.member?(runtime_app_names, app_name)

      %{
        name: name,
        requirement: req_info["requirement"] || "~> 0.0",
        optional: req_info["optional"] || false,
        runtime: is_runtime,
        app: req_info["app"]
      }
    end)
    |> Enum.sort_by(& &1.name)
  end
end
