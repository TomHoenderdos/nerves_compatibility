defmodule NccWorker.FileArchiver do
  @moduledoc """
  Archives files from package manifests by their SHA256 hash.

  Files are saved to an archive directory using their SHA256 hash as the filename.
  This naturally deduplicates files - if multiple packages have the same file,
  it will only be stored once.
  """

  require Logger

  @doc """
  Archives files from the result's beam_scan and dependency_scans manifests.

  Extracts all files referenced in the manifests and saves them by their SHA256 hash
  to the archive directory. Files that already exist (same hash) are skipped.

  ## Parameters
    - files_dir: Global files directory where all files are archived (e.g., /out/files or public/files)
    - result: Worker result map containing beam_scan and dependency_scans
    - work_dir: Path to the work directory where the project is located

  ## Returns
    - {:ok, stats} - Map with :files_archived, :files_skipped, :bytes_archived
    - {:error, reason} - If archiving fails
  """
  @spec archive_manifest_files(String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def archive_manifest_files(files_dir, result, work_dir) do
    File.mkdir_p!(files_dir)

    stats = %{files_archived: 0, files_skipped: 0, bytes_archived: 0}
    project_dir = Path.join(work_dir, "proj")

    # Collect all manifests from all systems
    manifests =
      result.systems
      |> Enum.flat_map(fn {system_name, system_result} ->
        collect_manifests_from_system(system_result, project_dir, system_name)
      end)

    # Archive each file
    final_stats =
      manifests
      |> Enum.reduce(stats, fn {source_path, entry}, acc ->
        case archive_file(files_dir, source_path, entry) do
          {:ok, :archived, bytes} ->
            %{
              acc
              | files_archived: acc.files_archived + 1,
                bytes_archived: acc.bytes_archived + bytes
            }

          {:ok, :skipped} ->
            %{acc | files_skipped: acc.files_skipped + 1}

          {:error, reason} ->
            Logger.warning(
              "Failed to archive #{source_path} (#{entry["sha256"]}): #{inspect(reason)}"
            )

            acc
        end
      end)

    {:ok, final_stats}
  end

  @spec collect_manifests_from_system(map(), String.t(), String.t()) ::
          [{String.t(), map()}]
  defp collect_manifests_from_system(system_result, project_dir, system_name) do
    # Skip non-build systems (like "host")
    if system_name == "host" do
      []
    else
      # The system_name is like "nerves_system_rpi4" but the build directory is "rpi4"
      # We need to find the actual build directory
      build_path = find_build_path(project_dir, system_name)

      if is_nil(build_path) do
        Logger.warning("Could not find build directory for system: #{system_name}")
        []
      else
        Logger.debug("Collecting manifests for #{system_name} from build_path: #{build_path}")

        # Get the package's own beam_scan
        package_files = collect_manifest_entries(system_result[:beam_scan], build_path, "package")

        # Get all dependency scans
        dependency_files =
          case system_result[:dependency_scans] do
            nil ->
              []

            deps when is_map(deps) ->
              deps
              |> Enum.flat_map(fn {app_version, dep_scan} ->
                collect_manifest_entries(dep_scan, build_path, app_version)
              end)

            _ ->
              []
          end

        all_files = package_files ++ dependency_files
        Logger.debug("Found #{length(all_files)} files to archive for #{system_name}")
        all_files
      end
    end
  end

  @spec find_build_path(String.t(), String.t()) :: String.t() | nil
  defp find_build_path(project_dir, system_name) do
    build_dir = Path.join(project_dir, "_build")

    if File.dir?(build_dir) do
      # Look for a directory that might match this system
      # Try common patterns: rpi4, mangopi_mq_pro, x86_64, etc.
      # The system_name is like "nerves_system_rpi4", extract the suffix
      target_suffix =
        system_name
        |> String.replace_prefix("nerves_system_", "")

      candidate = Path.join(build_dir, target_suffix)

      if File.dir?(candidate) do
        candidate
      else
        # Fall back to finding any directory in _build
        case File.ls(build_dir) do
          {:ok, dirs} ->
            # Look for directories that exist and might be a target
            dirs
            |> Enum.find_value(fn dir ->
              path = Path.join(build_dir, dir)
              if File.dir?(path) && String.contains?(system_name, dir), do: path
            end)

          _ ->
            nil
        end
      end
    else
      nil
    end
  end

  @spec collect_manifest_entries(map() | nil, String.t(), String.t()) ::
          [{String.t(), map()}]
  defp collect_manifest_entries(nil, _build_path, _source), do: []

  defp collect_manifest_entries(scan, build_path, source) do
    # The manifest is in footprint.file_manifest with ebin/priv keys
    # Try footprint.file_manifest first (current structure)
    footprint = get_in(scan, ["footprint"]) || get_in(scan, [:footprint])

    entries =
      if footprint do
        file_manifest = footprint["file_manifest"] || footprint[:file_manifest]

        if file_manifest do
          ebin = file_manifest["ebin"] || file_manifest[:ebin] || []
          priv = file_manifest["priv"] || file_manifest[:priv] || []
          Logger.debug("#{source}: Found #{length(ebin)} ebin files, #{length(priv)} priv files")

          ebin ++ priv
        else
          # Fall back to old structure (footprint.manifest - single list)
          manifest = footprint["manifest"] || footprint[:manifest] || []
          Logger.debug("#{source}: Using old manifest structure with #{length(manifest)} files")
          manifest
        end
      else
        # Try top-level file_manifest (if structure changes)
        file_manifest = get_in(scan, ["file_manifest"]) || get_in(scan, [:file_manifest])

        if file_manifest do
          ebin = file_manifest["ebin"] || file_manifest[:ebin] || []
          priv = file_manifest["priv"] || file_manifest[:priv] || []

          Logger.debug(
            "#{source}: Found #{length(ebin)} ebin files, #{length(priv)} priv files (top-level)"
          )

          ebin ++ priv
        else
          Logger.debug("#{source}: No manifest found in scan")
          []
        end
      end

    # Map each manifest entry to {source_path, entry}
    entries
    |> Enum.map(fn entry ->
      # The manifest entry has a relative path like "ebin/myapp.beam" or "priv/static/file.js"
      # We need to locate this in the build directory structure
      relative_path = entry["path"] || entry[:path]
      source_path = find_file_in_build(build_path, relative_path)

      if is_nil(source_path) do
        Logger.debug("Could not find file for path: #{relative_path}")
      end

      {source_path, entry}
    end)
    |> Enum.reject(fn {source, _entry} -> is_nil(source) end)
  end

  @spec find_file_in_build(String.t(), String.t()) :: String.t() | nil
  defp find_file_in_build(build_path, relative_path) do
    # The file should be in the release directory structure
    # Try both "rel" (for firmware builds) and "dev/rel" (for other builds)
    rel_paths = [
      Path.join(build_path, "rel"),
      Path.join([build_path, "dev", "rel"])
    ]

    rel_paths
    |> Enum.find_value(fn rel_dir ->
      if File.dir?(rel_dir) do
        # Find the file by searching in the release directory
        pattern = Path.join([rel_dir, "**", relative_path])

        case Path.wildcard(pattern) do
          [path | _] -> path
          [] -> nil
        end
      end
    end)
  end

  @spec archive_file(String.t(), String.t(), map()) ::
          {:ok, :archived, non_neg_integer()} | {:ok, :skipped} | {:error, term()}
  defp archive_file(archive_dir, source_path, entry) do
    sha256 = entry["sha256"] || entry[:sha256]

    if is_nil(sha256) or sha256 == "" do
      {:error, :no_hash}
    else
      dest_path = Path.join(archive_dir, sha256)

      # Skip if file already exists
      if File.exists?(dest_path) do
        {:ok, :skipped}
      else
        # Copy the file to the archive
        case File.cp(source_path, dest_path) do
          :ok ->
            # Normalize non-executable permissions on all files
            File.chmod!(dest_path, 0o644)

            # Return the size
            %{size: size} = File.stat!(dest_path)
            {:ok, :archived, size}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end
end
