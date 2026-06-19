defmodule NccWorker.AppFile do
  @moduledoc """
  Parses Erlang .app files to extract runtime application dependencies.
  """

  @doc """
  Reads a .app file and extracts the list of runtime application dependencies.

  ## Parameters
    - app_file_path: Path to the .app file

  ## Returns
    - {:ok, applications} - List of application atoms that are runtime dependencies
    - {:error, reason} - Failed to read or parse the .app file
  """
  @spec read_applications(String.t()) :: {:ok, [atom()]} | {:error, term()}
  def read_applications(app_file_path) do
    with {:ok, content} <- File.read(app_file_path),
         {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(content)),
         {:ok, term} <- :erl_parse.parse_term(tokens) do
      extract_applications(term)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds the .app file for a package in the release directory.

  ## Parameters
    - project_dir: Root directory of the Mix project
    - package_name: Name of the package to find

  ## Returns
    - {:ok, path} - Path to the .app file
    - {:error, reason} - Failed to find the .app file
  """
  @spec find_app_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def find_app_file(project_dir, package_name) do
    # Look for the .app file in the release directory
    # Pattern: _build/*/rel/*/lib/#{package_name}-*/ebin/#{package_name}.app
    build_dir = Path.join(project_dir, "_build")

    case File.ls(build_dir) do
      {:ok, targets} ->
        find_app_in_targets(build_dir, targets, package_name)

      {:error, reason} ->
        {:error, {:build_dir_error, reason}}
    end
  end

  defp find_app_in_targets(build_dir, targets, package_name) do
    # Try each target directory
    Enum.reduce_while(targets, {:error, :not_found}, fn target, _acc ->
      rel_dir = Path.join([build_dir, target, "rel"])

      case File.ls(rel_dir) do
        {:ok, apps} ->
          case find_app_in_releases(rel_dir, apps, package_name) do
            {:ok, path} -> {:halt, {:ok, path}}
            {:error, _} -> {:cont, {:error, :not_found}}
          end

        {:error, _} ->
          {:cont, {:error, :not_found}}
      end
    end)
  end

  defp find_app_in_releases(rel_dir, apps, package_name) do
    Enum.reduce_while(apps, {:error, :not_found}, fn app, _acc ->
      lib_dir = Path.join([rel_dir, app, "lib"])

      case File.ls(lib_dir) do
        {:ok, packages} ->
          # Find package directory matching package_name-version pattern
          package_dir =
            Enum.find(packages, fn pkg ->
              String.starts_with?(pkg, "#{package_name}-")
            end)

          if package_dir do
            app_file = Path.join([lib_dir, package_dir, "ebin", "#{package_name}.app"])

            if File.exists?(app_file) do
              {:halt, {:ok, app_file}}
            else
              {:cont, {:error, :not_found}}
            end
          else
            {:cont, {:error, :not_found}}
          end

        {:error, _} ->
          {:cont, {:error, :not_found}}
      end
    end)
  end

  # Extract applications list from parsed Erlang term
  # Expected format: {:application, app_name, properties}
  # where properties is a keyword list containing {:applications, [app_list]}
  defp extract_applications({:application, _app_name, properties}) when is_list(properties) do
    case List.keyfind(properties, :applications, 0) do
      {:applications, apps} when is_list(apps) ->
        {:ok, apps}

      _ ->
        {:ok, []}
    end
  end

  defp extract_applications(_), do: {:error, :invalid_app_file_format}
end
