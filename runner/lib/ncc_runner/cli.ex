defmodule NccRunner.CLI do
  @moduledoc """
  Command-line interface for the NCC Runner.

  Usage:
      ncc_runner run --input <path/to/job.json> --output-dir <dir> [--work-dir <dir>]

  Exit codes:
      0  - Success (worker produced outputs, even if builds failed)
      20 - Runner error (bad input, docker unavailable, outputs missing, etc.)
      21 - Worker container exited with non-zero code
  """

  alias NccRunner.{Docker, Job, Metadata}

  @doc """
  Main entry point for the escript.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    args
    |> parse_args()
    |> run()
    |> handle_exit()
  end

  defp parse_args(args) do
    {opts, remaining, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          output_dir: :string,
          work_dir: :string,
          help: :boolean
        ],
        aliases: [
          i: :input,
          o: :output_dir,
          w: :work_dir,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        :help

      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}"}

      remaining != ["run"] ->
        {:error, "Unknown command. Expected: run"}

      !opts[:input] ->
        {:error, "Missing required option: --input"}

      !opts[:output_dir] ->
        {:error, "Missing required option: --output-dir"}

      true ->
        {:ok, opts}
    end
  end

  defp run(:help) do
    IO.puts("""
    NCC Runner - Host-side program for running NCC worker containers

    Usage:
        ncc_runner run --input <path/to/job.json> --output-dir <dir> [options]

    Required Options:
        --input, -i <path>        Path to job.json file
        --output-dir, -o <dir>    Directory for outputs (result.json, logs)

    Optional:
        --work-dir, -w <dir>      Working directory (default: temp dir)
        --help, -h                Show this help

    Exit Codes:
        0   Success - worker produced outputs
        20  Runner error - bad input, docker issue, etc.
        21  Worker failed - container exited non-zero

    Examples:
        ncc_runner run --input job.json --output-dir ./out
        ncc_runner run -i job.json -o ./out -w ./work
    """)

    {:ok, 0}
  end

  defp run({:error, message}) do
    IO.puts(:stderr, "Error: #{message}")
    IO.puts(:stderr, "\nRun 'ncc_runner run --help' for usage information.")
    {:ok, 20}
  end

  defp run({:ok, opts}) do
    input_path = Path.expand(opts[:input])
    output_dir = Path.expand(opts[:output_dir])

    {work_dir, cleanup_work_dir?} =
      if opts[:work_dir] do
        {Path.expand(opts[:work_dir]), false}
      else
        {create_temp_work_dir(), true}
      end

    started_at = DateTime.utc_now()

    result =
      case execute_run(input_path, output_dir, work_dir, started_at) do
        {:ok, exit_code} ->
          {:ok, exit_code}

        {:error, message} ->
          IO.puts(:stderr, "Runner error: #{message}")
          {:ok, 20}
      end

    # Clean up temporary work directory if we created it
    if cleanup_work_dir? do
      File.rm_rf(work_dir)
    end

    result
  end

  defp execute_run(input_path, output_dir, work_dir, started_at) do
    with {:ok, job} <- load_job(input_path),
         :ok <- validate_docker(),
         :ok <- File.mkdir_p(output_dir),
         :ok <- File.mkdir_p(work_dir) do
      # Use files_dir from job or default to public/site/files (relative to project root)
      files_dir = job.files_dir || Path.join([File.cwd!(), "..", "public", "site", "files"]) |> Path.expand()
      File.mkdir_p!(files_dir)

      run_opts = %{
        work_dir: work_dir,
        output_dir: output_dir,
        files_dir: files_dir,
        cache_dir: job.cache_dir,
        log_file: Path.join(output_dir, "runner.log")
      }

      case Docker.run(job, run_opts) do
        {:ok, docker_result} ->
          completed_at = DateTime.utc_now()
          process_result(job, docker_result, run_opts, started_at, completed_at)

        {:error, reason} ->
          {:error, "Docker execution failed: #{reason}"}
      end
    end
  end

  defp load_job(input_path) do
    case Job.load(input_path) do
      {:ok, job} ->
        IO.puts("Loaded job: #{job.run_id}")
        IO.puts("Image: #{Job.image_ref(job)}")
        IO.puts("Package: #{job.package["name"]} #{job.package["version"]}")
        {:ok, job}

      {:error, reason} ->
        {:error, "Failed to load job: #{reason}"}
    end
  end

  defp validate_docker() do
    case Docker.check_docker() do
      {:ok, version} ->
        IO.puts("Docker version: #{version}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_result(job, docker_result, run_opts, started_at, completed_at) do
    container_exit = docker_result.exit_code
    result_path = Path.join(run_opts.output_dir, "result.json")

    # Validate outputs exist
    outputs_validated = File.exists?(result_path)

    # Determine runner exit code
    runner_exit_code =
      cond do
        container_exit != 0 ->
          IO.puts(:stderr, "Worker container exited with code: #{container_exit}")
          21

        !outputs_validated ->
          IO.puts(:stderr, "Worker did not produce result.json")
          20

        true ->
          IO.puts("Worker completed successfully")
          0
      end

    # Write metadata
    metadata_result =
      docker_result
      |> Map.put(:runner_exit_code, runner_exit_code)
      |> Map.put(:outputs_validated, outputs_validated)

    metadata = Metadata.generate(job, metadata_result, started_at, completed_at)
    metadata_path = Path.join(run_opts.output_dir, "runner_metadata.json")

    case Metadata.write(metadata, metadata_path) do
      :ok ->
        IO.puts("Metadata written to: #{metadata_path}")
        IO.puts("Duration: #{div(metadata.duration_ms, 1000)}s")

        if docker_result.flags_skipped != [] do
          IO.puts("Note: Some security flags were skipped:")

          Enum.each(docker_result.flags_skipped, fn flag ->
            IO.puts("  - #{flag}")
          end)
        end

        {:ok, runner_exit_code}

      {:error, reason} ->
        IO.puts(:stderr, "Warning: Failed to write metadata: #{reason}")
        {:ok, runner_exit_code}
    end
  end

  defp create_temp_work_dir() do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    temp_base = System.tmp_dir!()
    work_dir = Path.join(temp_base, "ncc_runner_#{timestamp}_#{random}")

    File.mkdir_p!(work_dir)
    work_dir
  end

  defp handle_exit({:ok, code}) do
    System.halt(code)
  end
end
