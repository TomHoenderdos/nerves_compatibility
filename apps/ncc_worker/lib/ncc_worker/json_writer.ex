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
  # The runner supplies output_dir as its container mount; result.json and its temp name are fixed.
  # sobelow_skip ["Traversal.FileModule"]
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
    json = %{
      run_id: result.run_id,
      package: Map.get(result, :package),
      image: result.image,
      toolchain: result.toolchain,
      systems:
        result.systems
        |> Enum.map(fn {system_name, system_result} ->
          {system_name, convert_system_result(system_result)}
        end)
        |> Map.new(),
      finished_at: result.finished_at,
      argus: Map.get(result, :argus),
      scope: Map.get(result, :scope, "full")
    }

    # Each absent rather than null when the result has none: `deps_lock` and
    # `package_checksum` when the worker could not read the lock (the way a run
    # from an image before lock recording looks too), `optional_deps` for
    # argus-only runs, which publish nothing, `toolchain_build` and
    # `requested_toolchain` for every run but a toolchain one
    # (`NccWorker.Worker.toolchain_build/4`), `nerves_cache` for a run with
    # no Nerves cache misses or locked Nerves packages
    # (`NccWorker.NervesCache.report/2`), and `warm` for every run but a warm
    # one (`NccWorker.WarmNerves`).
    json =
      [
        :deps_lock,
        :package_checksum,
        :optional_deps,
        :toolchain_build,
        :requested_toolchain,
        :nerves_cache,
        :warm
      ]
      |> Enum.reduce(json, &put_present(&2, &1, Map.get(result, &1)))

    # Candidates for the host to promote into the shared build cache, one per
    # stored build of the package under test. Absent when there are none, the
    # way a run with the cache off looks.
    candidates =
      result.systems
      |> Enum.flat_map(fn {_name, sys} -> Map.get(sys, :cache_candidates, []) end)
      |> Enum.uniq_by(& &1["key"])

    case candidates do
      [] -> json
      list -> Map.put(json, :cache, %{candidates: list})
    end
  end

  defp put_present(json, _key, nil), do: json
  defp put_present(json, key, value), do: Map.put(json, key, value)

  @spec convert_system_result(map()) :: map()
  defp convert_system_result(system_result) do
    %{
      status: Compatibility.Types.status_to_string(system_result.status),
      duration_sec: system_result.duration_sec,
      phase_timings: Map.get(system_result, :phase_timings),
      firmware_size_bytes: system_result.firmware_size_bytes,
      log_tail: system_result.log_tail,
      system_version: Map.get(system_result, :system_version),
      compile_env: Map.get(system_result, :compile_env),
      beam_scan: Map.get(system_result, :beam_scan),
      dependency_scans: Map.get(system_result, :dependency_scans),
      error: system_result.error
    }
  end
end
