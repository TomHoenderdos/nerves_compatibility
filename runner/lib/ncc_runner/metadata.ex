defmodule NccRunner.Metadata do
  @moduledoc """
  Metadata recording for deterministic build tracking.

  Records:
  - Job payload (sanitized)
  - Host OS information
  - Docker version
  - Resolved image reference
  - Timestamps and durations
  - Security flags applied or skipped
  """

  alias NccRunner.Job

  @type t :: %{
          run_id: String.t(),
          started_at: String.t(),
          completed_at: String.t(),
          duration_ms: non_neg_integer(),
          runner_version: String.t(),
          host: host_info(),
          docker: docker_info(),
          job: job_info(),
          result: result_info()
        }

  @type host_info :: %{
          os_type: String.t(),
          os_version: String.t(),
          arch: String.t(),
          elixir_version: String.t(),
          erlang_version: String.t()
        }

  @type docker_info :: %{
          version: String.t(),
          image_ref: String.t(),
          platform: nil | String.t(),
          flags_skipped: [String.t()]
        }

  @type job_info :: %{
          image_name: String.t(),
          image_digest: String.t(),
          package: map(),
          systems_override: nil | [String.t()],
          limits: nil | map(),
          docker_config: nil | map()
        }

  @type result_info :: %{
          exit_code: non_neg_integer(),
          exit_code_name: String.t(),
          outputs_validated: boolean()
        }

  @doc """
  Generate metadata for a completed run.
  """
  @spec generate(Job.t(), map(), DateTime.t(), DateTime.t()) :: t()
  def generate(%Job{} = job, run_result, started_at, completed_at) do
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    %{
      run_id: job.run_id,
      started_at: DateTime.to_iso8601(started_at),
      completed_at: DateTime.to_iso8601(completed_at),
      duration_ms: duration_ms,
      runner_version: runner_version(),
      host: collect_host_info(),
      docker: %{
        version: run_result.docker_version,
        image_ref: Job.image_ref(job),
        platform: get_platform(job),
        flags_skipped: run_result.flags_skipped
      },
      job: %{
        image_name: job.image_name,
        image_digest: job.image_digest,
        package: job.package,
        systems_override: job.systems_override,
        limits: job.limits,
        docker_config: sanitize_docker_config(job.docker)
      },
      result: %{
        exit_code: run_result.exit_code,
        exit_code_name: NccRunner.exit_code_name(run_result.runner_exit_code),
        outputs_validated: run_result.outputs_validated
      }
    }
  end

  @doc """
  Write metadata to a JSON file.
  """
  @spec write(t(), Path.t()) :: :ok | {:error, atom()}
  def write(metadata, path) do
    json = JSON.encode_to_iodata!(metadata)
    File.write(path, json)
  end

  # Private helpers

  defp runner_version() do
    case :application.get_key(:ncc_runner, :vsn) do
      {:ok, version} -> List.to_string(version)
      :undefined -> "dev"
    end
  end

  defp collect_host_info() do
    {os_family, os_name} = :os.type()

    os_version =
      case :os.version() do
        {major, minor, patch} -> "#{major}.#{minor}.#{patch}"
        version -> inspect(version)
      end

    %{
      os_type: "#{os_family}/#{os_name}",
      os_version: os_version,
      arch: to_string(:erlang.system_info(:system_architecture)),
      elixir_version: System.version(),
      erlang_version: to_string(:erlang.system_info(:otp_release))
    }
  end

  defp get_platform(%Job{docker: docker}) when is_map(docker) do
    Map.get(docker, :platform)
  end

  defp get_platform(_job), do: nil

  defp sanitize_docker_config(nil), do: nil

  defp sanitize_docker_config(config) when is_map(config) do
    # Remove any sensitive fields if added in the future
    config
  end
end
