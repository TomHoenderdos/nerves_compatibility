defmodule Site.PrecompiledManifest do
  @moduledoc """
  Generates per-package precompiled manifests listing all known versions and systems
  and the content-addressed files produced by each build.
  """

  @doc """
  Generates precompiled manifests from result files.

  Reads all result.json files from the input directory and generates one manifest
  per package in the output directory.

  ## Parameters
    - input_dir: Directory containing result.json files (e.g., compat_test_results)
    - output_dir: Directory to write manifest files (e.g., public/site/manifests)

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  @spec generate_manifests(String.t(), String.t()) :: :ok | {:error, term()}
  def generate_manifests(input_dir, output_dir) do
    File.mkdir_p!(output_dir)

    # Find all result JSON files
    result_files = Path.wildcard(Path.join(input_dir, "*.json"))

    if result_files == [] do
      IO.puts("No result files found in #{input_dir}")
      {:error, :no_files}
    else
      # Group results by package name
      manifests = build_manifests_from_results(result_files)

      # Write manifest files
      Enum.each(manifests, fn {package_name, manifest_data} ->
        write_manifest(output_dir, package_name, manifest_data)
      end)

      # Discovery stub — a client with a manifest URL can fetch
      # ../manifests/_meta.json to learn the canonical files-base URL
      # without hardcoding it. When the binaries service moves to its
      # own domain (prebuilt.embedded-elixir.com) this is the one place
      # that propagates the change to every consumer.
      meta = %{
        "schema" => 1,
        "files_base" => Site.Config.precompiled_files_base(),
        "manifests_base" => Site.Config.precompiled_manifests_base()
      }

      File.write!(Path.join(output_dir, "_meta.json"), JSON.encode_to_iodata!(meta))

      IO.puts("✓ Generated #{map_size(manifests)} precompiled manifests")
      :ok
    end
  end

  @spec build_manifests_from_results([String.t()]) :: %{String.t() => map()}
  defp build_manifests_from_results(result_files) do
    result_files
    |> Enum.reduce(%{}, fn file, acc ->
      case load_result_file(file) do
        {:ok, result} ->
          merge_result_into_manifests(acc, result)

        {:error, _reason} ->
          acc
      end
    end)
  end

  @spec load_result_file(String.t()) :: {:ok, map()} | {:error, term()}
  defp load_result_file(file) do
    with {:ok, content} <- File.read(file),
         {:ok, data} <- JSON.decode(content) do
      {:ok, data}
    end
  end

  @spec merge_result_into_manifests(map(), map()) :: map()
  defp merge_result_into_manifests(manifests, result) do
    package_name = get_in(result, ["package", "name"])
    package_version = get_in(result, ["package", "version"])

    if package_name && package_version do
      # Extract file manifests from all systems
      system_manifests = extract_system_manifests(result)

      if system_manifests != %{} do
        # Get or create manifest for this package
        package_manifest = Map.get(manifests, package_name, %{"versions" => %{}})

        # Add/update this version's data
        versions = package_manifest["versions"]
        version_data = Map.get(versions, package_version, %{})
        updated_version_data = Map.merge(version_data, system_manifests)

        updated_manifest =
          package_manifest
          |> Map.put("versions", Map.put(versions, package_version, updated_version_data))
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        Map.put(manifests, package_name, updated_manifest)
      else
        manifests
      end
    else
      manifests
    end
  end

  @spec extract_system_manifests(map()) :: map()
  defp extract_system_manifests(result) do
    systems = result["systems"] || %{}

    systems
    |> Enum.reduce(%{}, fn {system_name, system_result}, acc ->
      # Skip non-build systems
      if system_name == "host" do
        acc
      else
        case extract_file_manifest(system_result) do
          nil -> acc
          manifest -> Map.put(acc, system_name, manifest)
        end
      end
    end)
  end

  @spec extract_file_manifest(map()) :: map() | nil
  defp extract_file_manifest(system_result) when is_map(system_result) do
    # Get the package's beam_scan (not dependencies)
    beam_scan = system_result["beam_scan"]

    if beam_scan do
      footprint = beam_scan["footprint"]

      if footprint do
        file_manifest = footprint["file_manifest"]

        if file_manifest do
          %{
            "ebin" => file_manifest["ebin"] || [],
            "priv" => file_manifest["priv"] || []
          }
        end
      end
    end
  end

  defp extract_file_manifest(_), do: nil

  @spec write_manifest(String.t(), String.t(), map()) :: :ok
  defp write_manifest(output_dir, package_name, manifest_data) do
    manifest_file = Path.join(output_dir, "#{package_name}.json")
    temp_file = "#{manifest_file}.tmp"

    json_content = JSON.encode_to_iodata!(manifest_data)

    File.write!(temp_file, json_content)
    File.rename!(temp_file, manifest_file)
  end
end
