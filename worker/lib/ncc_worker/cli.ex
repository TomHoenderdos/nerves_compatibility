defmodule NccWorker.CLI do
  @moduledoc """
  CLI entrypoint for the NCC worker.

  Reads input from NCC_INPUT environment variable (default: /work/input.json),
  runs the worker, and writes results to the output directory.

  Exit codes:
  - 0: Worker completed successfully
  - 10: Worker internal failure
  - 11: Policy violation
  """

  alias NccWorker.Worker
  alias NccWorker.JsonWriter
  alias NccWorker.Project
  alias NccWorker.FileArchiver

  @spec main(list(String.t())) :: no_return()
  def main(args) do
    exit_code =
      case args do
        ["setup"] -> setup_only()
        _ -> run()
      end
      |> case do
        :ok -> 0
        {:error, :policy_violation} -> 11
        {:error, _} -> 10
      end

    System.halt(exit_code)
  end

  @spec run() :: :ok | {:error, term()}
  defp run() do
    with {:ok, input_path} <- get_input_path(),
         {:ok, input} <- read_input(input_path),
         {:ok, result} <- Worker.run(input),
         {:ok, output_dir} <- get_output_dir(input),
         {:ok, work_dir} <- get_work_dir_for_result(input),
         {:ok, files_dir} <- get_files_dir(input),
         {:ok, archive_stats} <-
           FileArchiver.archive_manifest_files(files_dir, result, work_dir),
         :ok <- JsonWriter.write_result(output_dir, result) do
      IO.puts(
        "Archived #{archive_stats.files_archived} files (#{archive_stats.bytes_archived} bytes), skipped #{archive_stats.files_skipped} duplicates"
      )

      :ok
    else
      {:error, reason} = error ->
        IO.puts(:stderr, "Worker failed: #{inspect(reason)}")
        error
    end
  end

  @spec setup_only() :: :ok | {:error, term()}
  defp setup_only() do
    with {:ok, input_path} <- get_input_path(),
         {:ok, input} <- read_input(input_path),
         {:ok, work_dir} <- get_work_dir(input),
         {:ok, package} <- get_package(input),
         {:ok, project_dir} <- Project.create(work_dir, package, nil),
         {:ok, _} <- Project.add_package(project_dir, package) do
      IO.puts("Setup complete. Project ready in #{project_dir}")
      IO.puts("Run: cd proj && MIX_TARGET=<target> mix firmware")
      :ok
    else
      {:error, reason} = error ->
        IO.puts(:stderr, "Setup failed: #{inspect(reason)}")
        error
    end
  end

  @spec get_input_path() :: {:ok, String.t()} | {:error, term()}
  defp get_input_path() do
    path = System.get_env("NCC_INPUT", "/work/input.json")
    {:ok, path}
  end

  @spec get_output_dir(map()) :: {:ok, String.t()}
  defp get_output_dir(input) do
    dir = get_in(input, [:paths, :output_dir]) || "/out"
    {:ok, dir}
  end

  @spec get_work_dir(map()) :: {:ok, String.t()} | {:error, term()}
  defp get_work_dir(input) do
    case get_in(input, [:paths, :work_dir]) do
      nil -> {:error, :missing_work_dir}
      dir -> {:ok, dir}
    end
  end

  @spec get_work_dir_for_result(map()) :: {:ok, String.t()} | {:error, term()}
  defp get_work_dir_for_result(input) do
    # Use the work_dir from input, defaulting to /work if not specified
    dir = get_in(input, [:paths, :work_dir]) || "/work"
    {:ok, dir}
  end

  @spec get_files_dir(map()) :: {:ok, String.t()}
  defp get_files_dir(input) do
    # Get the global files directory from input, defaulting to /out/files
    dir = get_in(input, [:paths, :files_dir]) || "/out/files"
    {:ok, dir}
  end

  @spec get_package(map()) :: {:ok, map()} | {:error, term()}
  defp get_package(input) do
    case input[:package] do
      nil -> {:error, :missing_package}
      package -> {:ok, package}
    end
  end

  @spec read_input(String.t()) :: {:ok, map()} | {:error, term()}
  defp read_input(path) do
    case File.read(path) do
      {:ok, content} ->
        try do
          json_map = JSON.decode!(content)
          {:ok, atomize_keys(json_map)}
        rescue
          _ -> {:error, {:invalid_json, "Failed to decode JSON"}}
        end

      {:error, reason} ->
        {:error, {:cannot_read_input, reason}}
    end
  end

  @spec atomize_keys(map()) :: map()
  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = if is_map(v), do: atomize_keys(v), else: v
      {key, value}
    end)
    |> Map.new()
  end
end
