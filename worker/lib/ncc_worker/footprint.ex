defmodule NccWorker.Footprint do
  @moduledoc """
  Calculates footprint statistics for a package's compiled artifacts.

  This scans the release directory to count only the files that are actually
  included in the final release build (stripped BEAM files, .app files, and
  priv directory contents).
  """

  @doc """
  Calculates footprint statistics (file count and total bytes) for a package.

  ## Parameters
    - project_dir: Path to the project directory
    - package_name: Name of the package
    - systems: Optional list of system maps (%{name: "nerves_system_rpi4", target: "rpi4"})

  ## Returns
    - {:ok, stats} - Stats calculated successfully
    - {:error, reason} - Failed to calculate stats

  ## Stats structure
    %{
      file_manifest: %{
        ebin: [%{path: String.t(), sha256: String.t(), size: integer(), mode: integer()}],
        priv: [%{path: String.t(), sha256: String.t(), size: integer(), mode: integer()}]
      },
      per_system: %{
        system_name => %{
          file_count: integer(),
          total_bytes: integer(),
          firmware_bytes: integer() | nil,
          file_manifest: %{
            ebin: [%{path: String.t(), sha256: String.t(), size: integer(), mode: integer()}],
            priv: [%{path: String.t(), sha256: String.t(), size: integer(), mode: integer()}]
          }
        }
      }
    }
  """
  @spec calculate(String.t(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def calculate(project_dir, package_name, systems \\ []) do
    # Find all release directories across all targets and collect per-target stats
    build_dir = Path.join(project_dir, "_build")

    case find_all_release_dirs(build_dir) do
      {:ok, release_dirs} when release_dirs != [] ->
        system_name_by_target = Map.new(systems, fn system -> {system.target, system.name} end)
        firmware_sizes = find_firmware_sizes(build_dir)

        target_stats =
          release_dirs
          |> Enum.map(fn {target, release_dir} ->
            with {:ok, package_lib_dir} <- find_package_in_release(release_dir, package_name) do
              ebin_dir = Path.join(package_lib_dir, "ebin")
              priv_dir = Path.join(package_lib_dir, "priv")

              ebin_manifest = list_files_with_hash(ebin_dir, package_lib_dir)
              priv_manifest = list_files_with_hash(priv_dir, package_lib_dir)

              # Calculate stats from manifest
              ebin_bytes = Enum.sum(Enum.map(ebin_manifest, & &1.size))
              priv_bytes = Enum.sum(Enum.map(priv_manifest, & &1.size))
              ebin_count = length(ebin_manifest)
              priv_count = length(priv_manifest)

              system_name = Map.get(system_name_by_target, target, target)

              %{
                target: target,
                system_name: system_name,
                file_manifest: %{
                  ebin: ebin_manifest,
                  priv: priv_manifest
                },
                total_bytes: ebin_bytes + priv_bytes,
                file_count: ebin_count + priv_count,
                firmware_bytes: Map.get(firmware_sizes, target)
              }
            else
              {:error, _} ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if length(target_stats) > 0 do
          per_system =
            target_stats
            |> Enum.map(fn stats ->
              # TODO: remove target-name fallback once all packages are rerun with system mapping present
              key = stats.system_name

              {key,
               %{
                 file_count: stats.file_count,
                 total_bytes: stats.total_bytes,
                 firmware_bytes: stats.firmware_bytes,
                 file_manifest: stats.file_manifest
               }}
            end)
            |> Map.new()

          # Use first system's manifest as representative (files should be same across systems)
          first_manifest = hd(target_stats).file_manifest

          total_stats = %{
            file_manifest: first_manifest,
            per_system: per_system
          }

          {:ok, total_stats}
        else
          {:error, :package_not_in_release}
        end

      {:ok, []} ->
        {:error, :no_release_dirs_found}

      error ->
        error
    end
  end

  @spec find_all_release_dirs(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defp find_all_release_dirs(build_dir) do
    # Look for _build/<target>/rel/<app_name>/lib for all targets
    case File.ls(build_dir) do
      {:ok, entries} ->
        # Find all target directories (e.g., rpi4, x86_64, mangopi_mq_pro)
        release_dirs =
          entries
          |> Enum.flat_map(fn entry ->
            rel_path = Path.join([build_dir, entry, "rel"])

            if File.dir?(rel_path) do
              case File.ls(rel_path) do
                {:ok, [app_name | _]} ->
                  lib_dir = Path.join([rel_path, app_name, "lib"])
                  if File.dir?(lib_dir), do: [{entry, lib_dir}], else: []

                _ ->
                  []
              end
            else
              []
            end
          end)

        {:ok, release_dirs}

      _ ->
        {:error, :build_dir_not_found}
    end
  end

  @spec find_package_in_release(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp find_package_in_release(release_lib_dir, package_name) do
    # Look for package_name-version directory in release/lib
    case File.ls(release_lib_dir) do
      {:ok, entries} ->
        # Find directory that starts with package_name-
        package_dir =
          Enum.find_value(entries, fn entry ->
            if String.starts_with?(entry, package_name <> "-") do
              Path.join(release_lib_dir, entry)
            end
          end)

        if package_dir && File.dir?(package_dir) do
          {:ok, package_dir}
        else
          {:error, :package_not_in_release}
        end

      _ ->
        {:error, :release_lib_not_readable}
    end
  end

  @spec find_firmware_sizes(String.t()) :: %{optional(String.t()) => integer()}
  defp find_firmware_sizes(build_dir) do
    # MIX_BUILD_PATH is set to _build/<target>, so firmware lands at
    # _build/<target>/nerves/images/ (no dev/ subdirectory in this layout).
    case File.ls(build_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          images_dir = Path.join([build_dir, entry, "nerves", "images"])

          if File.dir?(images_dir) do
            case File.ls(images_dir) do
              {:ok, files} ->
                fw_file = Enum.find(files, &String.ends_with?(&1, ".fw"))

                if fw_file do
                  fw_path = Path.join(images_dir, fw_file)

                  case File.stat(fw_path) do
                    {:ok, %{size: size}} -> {entry, size}
                    _ -> nil
                  end
                end

              _ ->
                nil
            end
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @spec list_files_with_hash(String.t(), String.t()) :: [map()]
  defp list_files_with_hash(dir, base_dir) do
    if File.exists?(dir) && File.dir?(dir) do
      collect_files_with_hash(dir, base_dir)
    else
      []
    end
  end

  @spec collect_files_with_hash(String.t(), String.t()) :: [map()]
  defp collect_files_with_hash(dir, base_dir) do
    File.ls!(dir)
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) ->
          # Recursively collect files from subdirectories
          collect_files_with_hash(path, base_dir)

        File.regular?(path) ->
          # Compute SHA256 and get file info
          case compute_file_hash(path) do
            {:ok, sha256, size, mode} ->
              # Make path relative to base_dir for cleaner output
              relative_path = Path.relative_to(path, base_dir)
              [%{path: relative_path, sha256: sha256, size: size, mode: mode}]

            _ ->
              []
          end

        true ->
          # Skip symlinks and other file types
          []
      end
    end)
  rescue
    # If we can't read the directory, return empty list
    _ -> []
  end

  @spec compute_file_hash(String.t()) ::
          {:ok, String.t(), integer(), integer()} | {:error, term()}
  defp compute_file_hash(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{size: size, mode: mode}} <- File.stat(path) do
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:ok, hash, size, mode}
    end
  end
end
