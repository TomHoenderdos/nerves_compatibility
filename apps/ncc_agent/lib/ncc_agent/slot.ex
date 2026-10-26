defmodule NccAgent.Slot do
  @moduledoc """
  One build slot: verify the egress ruleset, claim, run the job, repeat.

  The claim is a long poll, so an empty answer (204) claims again at once
  (but at most once a second, in case the portal answers early). Errors
  back off from 30 s, doubling up to 5 min, and reset after a good claim.
  Every claim is preceded by `NccAgent.Egress.verify/0`. When it fails the
  slot reinstalls the ruleset once and verifies again; still failing, it
  claims nothing, reports `egress: "missing"` through `/status` and checks
  again in 60 s. Once
  `NccAgent.Updater.updating?/0` is set no slot claims again.

  The job runs in a task so the slot stays responsive: it traps exits,
  and when the VM stops (an update, systemd) `terminate/2` ends the job,
  kills its container and hands the lease back with exit code `20`.
  """
  use GenServer, shutdown: 90_000

  require Logger

  alias Compatibility.Builder.Argv
  alias NccAgent.{Client, Config, Docker, Egress, Identity, Job, Updater}

  @runner_failure 20
  @backoff_ms 30_000
  @max_backoff_ms 300_000
  @min_poll_ms 1_000
  @updating_poll_ms 30_000
  @egress_retry_ms 60_000

  def child_spec(n) do
    %{id: {__MODULE__, n}, start: {__MODULE__, :start_link, [n]}, shutdown: 90_000}
  end

  def start_link(n), do: GenServer.start_link(__MODULE__, n)

  @impl true
  def init(n) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)
    {:ok, %{n: n, backoff: @backoff_ms, job: nil}}
  end

  @impl true
  def handle_info(:tick, %{job: nil} = state) do
    started = System.monotonic_time(:millisecond)

    case step() do
      :none ->
        elapsed = System.monotonic_time(:millisecond) - started
        Process.send_after(self(), :tick, max(@min_poll_ms - elapsed, 0))
        {:noreply, %{state | backoff: @backoff_ms}}

      :updating ->
        Process.send_after(self(), :tick, @updating_poll_ms)
        {:noreply, state}

      :egress_missing ->
        Process.send_after(self(), :tick, @egress_retry_ms)
        {:noreply, state}

      :handed_back ->
        send(self(), :tick)
        {:noreply, %{state | backoff: @backoff_ms}}

      {:job, job} ->
        {:noreply, %{state | job: job, backoff: @backoff_ms}}

      {:error, reason} ->
        Logger.warning(
          "slot #{state.n}: #{inspect(reason)}; retrying in #{div(state.backoff, 1000)} s"
        )

        Process.send_after(self(), :tick, state.backoff)
        {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff_ms)}}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, outcome} ->
        Logger.info("lease #{job.lease_id} (#{job.run_id}): #{outcome}")

      {:error, reason} ->
        Logger.error("lease #{job.lease_id} (#{job.run_id}): #{inspect(reason)}")
    end

    send(self(), :tick)
    {:noreply, %{state | job: nil}}
  end

  # `Job.run/3` rescues what it can; a task killed from outside still hands
  # its lease back now rather than when the reaper notices, and its
  # container does not get to run on unattended.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{job: %{task: %Task{ref: ref}} = job} = state
      ) do
    Logger.error("slot #{state.n}: the job crashed: #{inspect(reason)}")
    if job.container, do: Docker.kill(job.config, job.container)

    case Client.complete(job.req, job.lease_id, @runner_failure, %{}) do
      {:ok, _} -> :ok
      {:error, why} -> Logger.warning("handing back #{job.lease_id}: #{inspect(why)}")
    end

    send(self(), :tick)
    {:noreply, %{state | job: nil}}
  end

  # The job task's link: its result arrives as the message above.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{job: %{} = job}) do
    Logger.warning("stopping: ending lease #{job.lease_id} and killing #{job.container}")
    Process.unlink(job.task.pid)
    Process.exit(job.task.pid, :kill)
    if job.container, do: Docker.kill(job.config, job.container)

    case Client.complete(job.req, job.lease_id, @runner_failure, %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("handing back #{job.lease_id}: #{inspect(reason)}")
    end
  end

  def terminate(_reason, _state), do: :ok

  defp step do
    if Updater.updating?(), do: :updating, else: claim_step()
  end

  defp claim_step do
    egress = ensure_egress()

    with {:ok, req} <- Identity.ensure() do
      if egress == :ok, do: claim(req), else: egress_missing(req)
    end
  end

  # A failed verify gets one reinstall (Docker restarting rewrites its
  # chains, an operator may flush them) before the slot gives up.
  defp ensure_egress do
    with {:error, why} <- Egress.verify() do
      Logger.warning("egress ruleset not in place, reinstalling: #{why}")

      case Egress.install() do
        :ok -> :ok
        {:error, install_why} -> Logger.error("egress install failed: #{install_why}")
      end

      with {:error, why} <- Egress.verify() do
        Logger.error("egress ruleset still not in place; not claiming: #{why}")
        {:error, why}
      end
    end
  end

  defp claim(req) do
    case Client.claim(req, 1, "ok") do
      :none -> :none
      {:ok, claim} -> start(req, claim)
      {:error, reason} -> {:error, reason}
    end
  end

  defp egress_missing(req) do
    case Client.status(req, "missing", 0) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("reporting egress missing: #{inspect(reason)}")
    end

    :egress_missing
  end

  defp start(req, claim) do
    config = Config.get()

    # `:updater_opts` is a test hook (see `NccAgent.Updater.maybe_update/3`); empty in a release.
    case Updater.maybe_update(claim, config, Application.get_env(:ncc_agent, :updater_opts, [])) do
      {:updating, version} ->
        hand_back(req, claim, version)

      :ok ->
        if Updater.updating?(),
          do: hand_back(req, claim, "the new release"),
          else: run_job(req, claim, config)
    end
  end

  defp run_job(req, claim, config) do
    task = Task.async(fn -> Job.run(req, claim, config) end)

    {:job,
     %{
       task: task,
       req: req,
       config: config,
       lease_id: claim["lease_id"],
       run_id: claim["run_id"],
       container: container(claim["run_id"])
     }}
  end

  # The VM is about to restart into a new release: the lease goes back to
  # the queue now rather than when the portal reaps it.
  defp hand_back(req, claim, version) do
    Logger.info("lease #{claim["lease_id"]} handed back for #{version}")

    case Client.complete(req, claim["lease_id"], @runner_failure, %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("handing back #{claim["lease_id"]}: #{inspect(reason)}")
    end

    :handed_back
  end

  defp container(run_id) when is_binary(run_id) do
    Argv.container_name(run_id)
  rescue
    ArgumentError -> nil
  end

  defp container(_run_id), do: nil
end
