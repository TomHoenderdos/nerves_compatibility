defmodule NccWorker.CLI do
  @moduledoc """
  CLI entrypoint for the NCC worker.

  Reads input from NCC_INPUT environment variable (default: /work/input.json),
  runs the worker, and writes results to the output directory. Before the
  compiled files are archived and `result.json` is written, every other
  process in the container is stopped (`NccWorker.ProcessSweep`); a result
  where that fails, or a portal build (`NCC_INPUT` set) where the sweep cannot
  run, passes nothing. `result.json` records how it went as `process_sweep`.

  Exit codes:
  - 0: Worker completed and wrote `result.json`, whatever the builds' verdicts
    (a toolchain run whose host compile failed included, and a full/targets
    run whose own `deps.get` failed deterministically -- see
    `NccWorker.DepsGetClassifier`)
  - 10: Worker internal failure: no `result.json` (e.g. `mix new` failed, or
    `deps.get` failed in a way `NccWorker.DepsGetClassifier` calls transient)
  - 11: Policy violation
  """

  alias NccWorker.Worker
  alias NccWorker.JsonWriter
  alias NccWorker.NervesCache
  alias NccWorker.Project
  alias NccWorker.Systems
  alias NccWorker.FileArchiver
  alias NccWorker.HexCache
  alias NccWorker.ProcessSweep

  @spec main(list(String.t())) :: no_return()
  def main(args) do
    :ok = scrub_env()
    # Before any lookup, so the native resolver never runs
    # (`NccWorker.ProcessSweep`).
    :ok = ProcessSweep.use_erlang_resolver()

    exit_code =
      case args do
        ["setup"] -> setup_only()
        _ -> run()
      end
      |> exit_code()

    System.halt(exit_code)
  end

  @doc """
  Maps `run/0`'s or `setup_only/0`'s outcome to a process exit code. Public
  and pure (no `System.halt/1`) so a test can call it directly.
  """
  @spec exit_code(:ok | {:error, term()}) :: 0 | 10 | 11
  def exit_code(:ok), do: 0
  def exit_code({:error, :policy_violation}), do: 11
  def exit_code({:error, _reason}), do: 10

  @doc """
  Removes `MIX_OS_DEPS_COMPILE_PARTITION_COUNT` before any `mix` starts, so
  every compile the worker runs builds dependencies one at a time in one VM:
  the compile-time trace (`NccWorker.Portability`) sees one VM and relies on
  that order. `mix ncc.trace_compile` refuses to start if it is set anyway.
  """
  @spec scrub_env() :: :ok
  def scrub_env do
    System.delete_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT")
    :ok
  end

  @spec run() :: :ok | {:error, term()}
  defp run() do
    with {:ok, input_path} <- get_input_path(),
         {:ok, input} <- read_input(input_path) do
      run_input(input, &Worker.run/1)
    else
      {:error, reason} = error ->
        IO.puts(:stderr, "Worker failed: #{inspect(reason)}")
        error
    end
  end

  @doc false
  # `run/0` once the input is read: `worker` is `Worker.run/1`, which tests
  # replace. `result.json` is written only for a worker `{:ok, result}`.
  @spec run_input(map(), (map() -> {:ok, map()} | {:error, term()})) :: :ok | {:error, term()}
  def run_input(input, worker) do
    with {:ok, result} <- worker.(input),
         # Nothing but the worker may still run while the files are archived
         # and result.json is written (`NccWorker.ProcessSweep`).
         result = ProcessSweep.enforce_and_report(result),
         {:ok, output_dir} <- get_output_dir(input),
         {:ok, work_dir} <- get_work_dir_for_result(input),
         {:ok, files_dir} <- get_files_dir(input),
         {:ok, archive_stats} <-
           FileArchiver.archive_manifest_files(files_dir, result, work_dir),
         :ok <- JsonWriter.write_result(output_dir, result),
         :ok <- result_outcome(result) do
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

  @doc """
  `:ok` (exit 0) for every written result, including a toolchain run whose
  host compile failed (`toolchain_build.status == "error"`). A compile failure
  is deterministic for that package, version and toolchain: the portal has to
  ingest it as a verdict, and retrying it would only fail the same way. Exit 10
  is left for runs that produced no result at all.
  """
  @spec result_outcome(map()) :: :ok
  def result_outcome(_result), do: :ok

  @spec setup_only() :: :ok | {:error, term()}
  defp setup_only() do
    with {:ok, input_path} <- get_input_path(),
         {:ok, input} <- read_input(input_path),
         {:ok, work_dir} <- get_work_dir(input),
         {:ok, package} <- get_package(input),
         {:ok, nerves} <- NervesCache.prepare(:build, work_dir: work_dir),
         :ok <- NervesCache.export_env(nerves),
         {:ok, hex} <- HexCache.prepare(work_dir: work_dir),
         :ok <- HexCache.export_env(hex),
         {:ok, project_dir} <-
           Project.create(work_dir, nil, Systems.targets(Systems.default())),
         {:ok, _} <-
           Project.add_package(project_dir, package, [
             {"MIX_BUILD_PATH", Path.join([project_dir, "_build", "host"])},
             {"MIX_DEPS_PATH", Path.join([project_dir, "deps"])},
             {"MIX_ENV", "prod"}
           ]) do
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
  # NCC_INPUT is set by the operator/runner to its mounted input.json, not by a web request.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_input(path) do
    case File.read(path) do
      {:ok, content} -> parse_input(content)
      {:error, reason} -> {:error, {:cannot_read_input, reason}}
    end
  end

  @doc false
  # The JSON-to-input transform `read_input/1` applies; public for tests.
  @spec parse_input(String.t()) ::
          {:ok, map()}
          | {:error,
             {:invalid_json, String.t()}
             | {:invalid_optional_deps, term()}
             | {:invalid_config_variant, term()}}
  def parse_input(content) do
    with {:ok, input} <- decode_input(content),
         {:ok, input} <- validate_optional_deps(input) do
      validate_config_variant(input)
    end
  end

  defp decode_input(content) do
    {:ok, content |> JSON.decode!() |> atomize_keys()}
  rescue
    _ -> {:error, {:invalid_json, "Failed to decode JSON"}}
  end

  # The portal builds a toolchain version per optional-deps variant and
  # records the result as the variant it asked for. A value that is neither
  # would run as some default and be recorded as the wrong variant, so it is
  # refused; an input without the key runs as before.
  defp validate_optional_deps(%{optional_deps: value})
       when value not in ["include", "exclude"],
       do: {:error, {:invalid_optional_deps, value}}

  defp validate_optional_deps(input), do: {:ok, input}

  # The portal records a toolchain build under the config variant it asked
  # for; a name this image does not pin would build some other config.
  defp validate_config_variant(%{config_variant: value} = input) do
    if Compatibility.ConfigVariants.known?(value),
      do: {:ok, input},
      else: {:error, {:invalid_config_variant, value}}
  end

  defp validate_config_variant(input), do: {:ok, input}

  @input_keys ~w(run_id image name digest package version requirement source paths work_dir output_dir files_dir limits per_system_timeout_sec log_tail_bytes systems_filter known_system_abi systems_override argus analyses scope timeout_seconds mode toolchain elixir otp nerves_packages system_abi egress_probe optional_deps config_variant judge makefile_rule2)a
  @input_key_map Map.new(@input_keys, &{Atom.to_string(&1), &1})

  @spec atomize_keys(map()) :: map()
  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      key = Map.get(@input_key_map, k, k)
      value = if is_map(v), do: atomize_keys(v), else: v
      {key, value}
    end)
    |> Map.new()
  end
end
