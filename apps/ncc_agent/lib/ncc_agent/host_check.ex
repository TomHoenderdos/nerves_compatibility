defmodule NccAgent.HostCheck do
  @moduledoc """
  What the builder host's docker daemon must provide before a slot claims:

    * a `runsc` runtime. Every build runs `docker run --runtime=runsc`
      (`Compatibility.Builder.Argv`), so a daemon without gVisor fails each
      build it is given.
    * `default-ulimits` `nofile` between 65536 and 1048576, soft and hard,
      in the daemon's `daemon.json` (`NCC_DOCKER_DAEMON_JSON`). Without it
      a container inherits a limit of about 2^31, the BEAM sizes its port
      table from it (some 2 GB, which gVisor charges to the container's
      memory cgroup) and every build is OOM-killed.

  `apps/ncc_agent/rel/overlays/builder-host-setup.sh` sets both. The nofile
  check reads the file rather than run a container, so a limit set only on
  dockerd's command line is not seen: keep it in `daemon.json`.
  """

  alias NccAgent.{Config, Docker}

  @min_nofile 65_536
  @max_nofile 1_048_576

  @spec check(Config.t()) :: :ok | {:error, String.t()}
  def check(config) do
    with :ok <- runsc(config), do: nofile(config.daemon_json)
  end

  defp runsc(config) do
    case Docker.runtimes(config) do
      {:ok, runtimes} ->
        if "runsc" in runtimes,
          do: :ok,
          else:
            {:error,
             "docker has no runsc runtime (registered: #{Enum.join(runtimes, ", ")}); " <>
               "every build runs under gVisor: run builder-host-setup.sh"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp nofile(path) do
    with {:ok, bytes} <- read(path),
         {:ok, doc} <- decode(path, bytes) do
      case get_in(doc, ["default-ulimits", "nofile"]) do
        %{"Soft" => soft, "Hard" => hard}
        when soft in @min_nofile..@max_nofile//1 and hard in soft..@max_nofile//1 ->
          :ok

        %{"Soft" => soft, "Hard" => hard} ->
          {:error,
           "docker default-ulimits nofile in #{path} is #{inspect(soft)}/#{inspect(hard)}, " <>
             "want 65536 (soft and hard, at most #{@max_nofile}): #{advice()}"}

        _ ->
          {:error, "docker default-ulimits nofile is not set in #{path}: #{advice()}"}
      end
    end
  end

  # The path is the operator's NCC_DOCKER_DAEMON_JSON, never job input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error,
         "cannot read #{path} (#{:file.format_error(reason)}), which must set docker " <>
           "default-ulimits nofile: #{advice()}"}
    end
  end

  defp decode(path, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, "#{path} is not valid JSON"}
    end
  end

  defp advice,
    do:
      "without it every build is OOM-killed under runsc; run builder-host-setup.sh " <>
        "or set it and restart docker"
end
