defmodule Orchestrator.Processor do
  @moduledoc """
  Processes package/version pairs from the queue by running compatibility checks.

  Pulls items from the queue, runs the NCC runner to test them against Nerves systems,
  saves the results, and regenerates the static site.
  """

  use GenServer
  require Logger

  @poll_interval :timer.seconds(10)

  ## Client API

  @doc """
  Starts the Processor GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current status of the processor.
  """
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Pauses processing (stops pulling from queue).
  """
  def pause() do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resumes processing.
  """
  def resume() do
    GenServer.call(__MODULE__, :resume)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      paused: false,
      current_item: nil,
      processed_count: 0,
      failed_count: 0,
      last_processed: nil,
      started_at: DateTime.utc_now()
    }

    Logger.info("Processor started")

    # Start processing shortly after startup
    Process.send_after(self(), :process_next, :timer.seconds(2))

    {:ok, state}
  end

  @impl true
  def handle_info(:process_next, %{paused: true} = state) do
    # If paused, check again later
    Process.send_after(self(), :process_next, @poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, state) do
    case Orchestrator.Queue.dequeue() do
      {:ok, {package, version} = item} ->
        Logger.info("Processing package: #{package}:#{version}")

        new_state = %{state | current_item: item}

        case process_package(package, version) do
          :ok ->
            Orchestrator.Queue.mark_checked(item)

            Logger.info("Successfully processed #{package}:#{version}")

            new_state = %{
              new_state
              | processed_count: state.processed_count + 1,
                last_processed: DateTime.utc_now(),
                current_item: nil
            }

            # Immediately check for next item
            send(self(), :process_next)
            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("Failed to process #{package}:#{version}: #{inspect(reason)}")

            new_state = %{
              new_state
              | failed_count: state.failed_count + 1,
                current_item: nil
            }

            # Wait a bit before retrying to avoid rapid failures
            Process.send_after(self(), :process_next, :timer.seconds(30))
            {:noreply, new_state}
        end

      :empty ->
        Logger.debug("Queue is empty, waiting...")
        Process.send_after(self(), :process_next, @poll_interval)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    queue_stats = Orchestrator.Queue.stats()

    status = %{
      paused: state.paused,
      current_item: state.current_item,
      processed_count: state.processed_count,
      failed_count: state.failed_count,
      last_processed: state.last_processed,
      started_at: state.started_at,
      queue_size: queue_stats.queue_size,
      next_in_queue: queue_stats.next_item
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Processor paused")
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Processor resumed")
    send(self(), :process_next)
    {:reply, :ok, %{state | paused: false}}
  end

  ## Private Helpers

  defp process_package(package, version) do
    Logger.info("Starting compatibility check for #{package}:#{version}")

    # Load package metadata
    metadata = Orchestrator.load_package_metadata()

    # Check if package should be skipped based on dependencies
    case check_dependency_skip(package, version, metadata) do
      {:skip, reason} ->
        Logger.info("Package #{package} skipped: #{reason}")
        create_forced_result(package, version, :skip, metadata, reason)

      :continue ->
        # Check if package has forced status
        case Compatibility.PackageMetadata.forced_status(metadata, package) do
          {:forced, status} ->
            Logger.info("Package #{package} has forced status: #{status}")
            create_forced_result(package, version, status, metadata, nil)

          :none ->
            # Normal processing
            result =
              with :ok <- create_job_file(package, version, metadata),
                   :ok <- run_compatibility_check(package, version),
                   :ok <- copy_results(package, version),
                   :ok <- regenerate_site() do
                :ok
              else
                {:error, reason} = error ->
                  Logger.error("Error processing #{package}:#{version}: #{inspect(reason)}")
                  error
              end

            # Clean up temporary files
            cleanup_temp_files(package, version)

            result
        end
    end
  end

  defp check_dependency_skip(package, version, metadata) do
    skip_deps = Compatibility.PackageMetadata.get_skip_dependencies(metadata)

    if skip_deps == [] do
      # No dependencies to skip, continue
      :continue
    else
      # Fetch package dependencies from Hex.pm
      case fetch_package_dependencies(package, version) do
        {:ok, dependencies} ->
          dep_names = Enum.map(dependencies, & &1["package"])

          if Compatibility.PackageMetadata.should_skip_by_dependency?(metadata, dep_names) do
            matching_deps = Enum.filter(dep_names, &(&1 in skip_deps))

            reason =
              "Package depends on #{Enum.join(matching_deps, ", ")} which are not compatible with the testing environment"

            {:skip, reason}
          else
            :continue
          end

        {:error, reason} ->
          Logger.warning(
            "Could not fetch dependencies for #{package}:#{version}: #{inspect(reason)}. Proceeding with testing."
          )

          :continue
      end
    end
  end

  defp fetch_package_dependencies(package, version) do
    url = "https://hex.pm/api/packages/#{package}/releases/#{version}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        requirements = body["requirements"] || %{}

        dependencies =
          Enum.map(requirements, fn {name, _req_info} ->
            %{"package" => name}
          end)

        {:ok, dependencies}

      {:ok, %{status: status}} ->
        {:error, {:hex_api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  rescue
    error ->
      {:error, {:exception, error}}
  end

  defp create_forced_result(package, version, status, metadata, custom_notes) do
    Logger.info("Creating forced result for #{package}:#{version} with status: #{status}")

    pkg_meta = Compatibility.PackageMetadata.get(metadata, package)
    results_dir = Orchestrator.results_dir()
    dest = Path.join(results_dir, "#{package}.json")

    logs_root = Path.join(results_dir, "logs")

    File.mkdir_p!(results_dir)
    File.mkdir_p!(logs_root)

    # Create a minimal result file with forced status
    # The status atom needs to be converted to string for JSON
    status_string =
      case status do
        :pass -> "pass"
        :fail -> "fail"
        :skip -> "skipped"
      end

    # Use custom_notes if provided, otherwise use package metadata notes
    notes = custom_notes || pkg_meta.notes

    forced_result = %{
      "image" => %{
        "name" => "forced",
        "digest" => "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      },
      "package" => %{
        "name" => package,
        "version" => version,
        "description" => "",
        "dependencies" => [],
        "footprint" => %{
          "priv" => %{"file_count" => 0, "total_bytes" => 0},
          "ebin" => %{"file_count" => 0, "total_bytes" => 0},
          "file_count" => 0,
          "total_bytes" => 0,
          "firmware_bytes" => nil
        }
      },
      "run_id" => "forced-#{package}-#{version}",
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "systems" => %{},
      "forced_status" => status_string,
      "notes" => notes,
      "toolchain" => %{
        "erlang" => "",
        "elixir" => "",
        "mix" => "",
        "nerves_bootstrap" => nil
      }
    }

    json_content = JSON.encode_to_iodata!(forced_result)
    File.write!(dest, json_content)

    Logger.info("Created forced result file: #{dest}")
    :ok
  rescue
    error ->
      {:error, {:create_forced_result, error}}
  end

  defp create_job_file(package, version, metadata) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    run_id = "#{package}-#{version}-#{timestamp}"
    image_name = Orchestrator.docker_image()

    # Get the image digest from Docker
    image_digest = get_image_digest(image_name)

    # Detect platform - for local images, don't force a platform
    platform = get_docker_platform(image_name)

    # Default systems (should match worker's default list)
    default_systems = [
      "nerves_system_rpi4",
      "nerves_system_mangopi_mq_pro",
      "nerves_system_x86_64"
    ]

    # Filter systems based on allow/deny lists
    filtered_systems = Compatibility.PackageMetadata.filter_systems(metadata, package, default_systems)

    # Set systems_filter if filtering resulted in a different list
    systems_filter =
      if filtered_systems == default_systems do
        nil
      else
        filtered_systems
      end

    job = %{
      "run_id" => run_id,
      "image_digest" => image_digest,
      "image_name" => image_name,
      "package" => %{
        "name" => package,
        "version" => version,
        "source" => "hex"
      },
      "systems_override" => nil,
      "systems_filter" => systems_filter,
      "limits" => %{
        "timeout_seconds" => 600,
        "max_log_bytes" => 10_485_760
      },
      "docker" => %{
        "platform" => platform,
        "network_mode" => "bridge",
        "memory" => "4g",
        "cpus" => "2",
        "pids_limit" => 1024
      },
      "cache_dir" => nil
    }

    tmp_dir = Orchestrator.runner_tmp_dir()
    File.mkdir_p!(tmp_dir)

    job_file = Path.join(tmp_dir, "#{package}-#{version}-job.json")
    File.write!(job_file, JSON.encode!(job))

    Logger.debug("Created job file: #{job_file}")
    :ok
  rescue
    error ->
      {:error, {:create_job_file, error}}
  end

  defp get_docker_platform(image_name) do
    # Check if image has linux/amd64 platform
    case System.cmd("docker", ["inspect", "--format={{.Architecture}}", image_name],
           stderr_to_stdout: true
         ) do
      {"amd64\n", 0} ->
        "linux/amd64"

      {"arm64\n", 0} ->
        "linux/arm64"

      _ ->
        # Default to linux/amd64 for production
        "linux/amd64"
    end
  end

  defp get_image_digest(image_name) do
    case System.cmd("docker", ["inspect", "--format={{.RepoDigests}}", image_name],
           stderr_to_stdout: true
         ) do
      {"[]\n", 0} ->
        # No digest available for local images, get the image ID instead
        case System.cmd("docker", ["inspect", "--format={{.Id}}", image_name],
               stderr_to_stdout: true
             ) do
          {id, 0} ->
            # Docker returns "sha256:abcdef..." - ensure it's properly formatted
            id
            |> String.trim()
            |> normalize_digest()

          {error, _} ->
            Logger.warning("Failed to get image ID for #{image_name}: #{error}")
            "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        end

      {digest_output, 0} ->
        # Extract first digest from [sha256:...] or [registry/image@sha256:...] format
        digest_output
        |> String.trim()
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split()
        |> List.first()
        |> case do
          nil ->
            "sha256:0000000000000000000000000000000000000000000000000000000000000000"

          d ->
            # Extract sha256:hash from registry/image@sha256:hash format
            d
            |> String.split("@")
            |> List.last()
            |> normalize_digest()
        end

      {error, _} ->
        Logger.warning("Failed to get image digest for #{image_name}: #{error}")
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  defp normalize_digest(digest) do
    # Ensure digest is in format sha256:<64-hex-chars>
    case String.split(digest, ":", parts: 2) do
      ["sha256", hash] ->
        # Ensure exactly 64 hex characters
        hash = String.slice(hash, 0, 64)

        if String.length(hash) == 64 and String.match?(hash, ~r/^[0-9a-f]+$/i) do
          "sha256:#{String.downcase(hash)}"
        else
          "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        end

      _ ->
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  defp run_compatibility_check(package, version) do
    runner_path = Orchestrator.runner_path()
    tmp_dir = Orchestrator.runner_tmp_dir()

    job_file = Path.join(tmp_dir, "#{package}-#{version}-job.json")
    output_dir = Path.join(tmp_dir, "#{package}-#{version}-results")

    # Clean output directory
    File.rm_rf!(output_dir)

    args = [
      "run",
      "--input",
      job_file,
      "--output-dir",
      output_dir
    ]

    Logger.info("Running: #{runner_path} #{Enum.join(args, " ")}")

    case System.cmd(runner_path, args, stderr_to_stdout: true, cd: Path.dirname(runner_path)) do
      {output, 0} ->
        Logger.debug("Runner completed successfully: #{output}")
        :ok

      {_output, 21} ->
        # Exit 21 = worker_failed: Worker ran but package failed to build/test
        # This is an expected outcome - we still want to save the results
        Logger.info("Package #{package}:#{version} failed compatibility check (worker exit code)")
        :ok

      {output, exit_code} ->
        # Exit 20 or other = actual runner error (bad input, docker issues, etc.)
        Logger.error("Runner error with exit code #{exit_code}: #{output}")
        {:error, {:runner_failed, exit_code, output}}
    end
  rescue
    error ->
      {:error, {:run_compatibility_check, error}}
  end

  defp copy_results(package, version) do
    tmp_dir = Orchestrator.runner_tmp_dir()
    results_dir = Orchestrator.results_dir()

    result_source = Path.join(tmp_dir, "#{package}-#{version}-results/result.json")
    metadata_source = Path.join(tmp_dir, "#{package}-#{version}-results/runner_metadata.json")
    logs_source = Path.join(tmp_dir, "#{package}-#{version}-results/logs")
    dest = Path.join(results_dir, "#{package}.json")
    logs_dest = Path.join(results_dir, "logs/#{package}")

    File.mkdir_p!(results_dir)

    result =
      cond do
        File.exists?(result_source) ->
          # Prefer result.json if available (complete results from worker)
          File.cp!(result_source, dest)
          Logger.info("Copied results to: #{dest}")
          :ok

        File.exists?(metadata_source) ->
          # Fall back to runner_metadata.json if worker didn't complete
          # This still contains useful information about the failure
          File.cp!(metadata_source, dest)
          Logger.info("Copied runner metadata to: #{dest} (worker did not produce result.json)")
          :ok

        true ->
          # No results at all - this is a real error
          Logger.error("No result files found in: #{Path.dirname(result_source)}")
          {:error, :no_results_found}
      end

    # Copy logs directory if it exists (regardless of result.json vs metadata.json)
    if result == :ok and File.dir?(logs_source) do
      logs_parent = Path.dirname(logs_dest)
      File.mkdir_p!(logs_parent)
      File.rm_rf!(logs_dest)
      File.cp_r!(logs_source, logs_dest)
      Logger.info("Copied logs to: #{logs_dest}")
    end

    result
  rescue
    error ->
      {:error, {:copy_results, error}}
  end

  defp regenerate_site() do
    results_dir = Orchestrator.results_dir()
    public_dir = Orchestrator.public_dir()
    data_dir = Path.join(public_dir, "data")

    cond do
      not File.dir?(results_dir) ->
        Logger.debug("regenerate_site: #{results_dir} does not exist yet")

      not any_result_json?(results_dir) ->
        Logger.debug("regenerate_site: no result files in #{results_dir} yet")

      true ->
        do_regenerate(results_dir, data_dir, public_dir)
    end

    # Site regeneration is best-effort: a failure here must not mark the
    # package run itself as failed. Always return :ok.
    :ok
  end

  defp any_result_json?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.any?(entries, &String.ends_with?(&1, ".json"))
      _ -> false
    end
  end

  defp do_regenerate(results_dir, data_dir, public_dir) do
    Mix.Tasks.ConvertResults.run(["--input", results_dir, "--output", data_dir])

    case Site.Generator.generate(input_dir: data_dir, output_dir: public_dir) do
      :ok ->
        Logger.info("Site regenerated at #{public_dir}")

      {:error, reason} ->
        Logger.warning("Site.Generator.generate failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("regenerate_site: #{Exception.message(e)}")
      Logger.debug(Exception.format(:error, e, __STACKTRACE__))
  end

  defp cleanup_temp_files(package, version) do
    tmp_dir = Orchestrator.runner_tmp_dir()
    job_file = Path.join(tmp_dir, "#{package}-#{version}-job.json")
    output_dir = Path.join(tmp_dir, "#{package}-#{version}-results")

    # Clean up job file
    if File.exists?(job_file) do
      File.rm(job_file)
      Logger.debug("Cleaned up job file: #{job_file}")
    end

    # Clean up output directory
    if File.dir?(output_dir) do
      File.rm_rf!(output_dir)
      Logger.debug("Cleaned up output directory: #{output_dir}")
    end
  rescue
    error ->
      Logger.warning("Failed to clean up temp files for #{package}:#{version}: #{inspect(error)}")
      :ok
  end
end
