defmodule NccWorker.JsonWriter do
  @moduledoc """
  Writes worker results to JSON files atomically.

  Uses atomic write (write to temp file, then rename) to ensure
  partial results are never visible.
  """

  @doc """
  Writes the result to result.json in the output directory.

  Uses atomic write to ensure the file is only visible when complete.

  ## Parameters
    - output_dir: Directory to write result.json to
    - result: Result map from Worker.run/1

  ## Returns
    - :ok - File written successfully
    - {:error, reason} - Write failed
  """
  @spec write_result(String.t(), map()) :: :ok | {:error, term()}
  def write_result(output_dir, result) do
    result_file = Path.join(output_dir, "result.json")
    temp_file = "#{result_file}.tmp"

    # Convert result to JSON
    json_content =
      result
      |> convert_result_for_json()
      |> JSON.encode_to_iodata!()

    # Write to temp file
    case File.write(temp_file, json_content) do
      :ok ->
        # Atomic rename
        case File.rename(temp_file, result_file) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rename_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  @spec convert_result_for_json(map()) :: map()
  defp convert_result_for_json(result) do
    %{
      run_id: result.run_id,
      package: result.package,
      image: result.image,
      toolchain: result.toolchain,
      systems:
        result.systems
        |> Enum.map(fn {system_name, system_result} ->
          {system_name, convert_system_result(system_result)}
        end)
        |> Map.new(),
      finished_at: result.finished_at
    }
  end

  @spec convert_system_result(map()) :: map()
  defp convert_system_result(system_result) do
    %{
      status: Compatibility.Types.status_to_string(system_result.status),
      duration_sec: system_result.duration_sec,
      firmware_size_bytes: system_result.firmware_size_bytes,
      log_tail: system_result.log_tail,
      system_version: Map.get(system_result, :system_version),
      beam_scan: Map.get(system_result, :beam_scan),
      dependency_scans: Map.get(system_result, :dependency_scans),
      deterministic: Map.get(system_result, :deterministic),
      determinism_changes: Map.get(system_result, :determinism_changes),
      error: system_result.error
    }
  end
end
