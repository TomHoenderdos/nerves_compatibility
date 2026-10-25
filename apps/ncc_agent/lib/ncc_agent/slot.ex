defmodule NccAgent.Slot do
  @moduledoc """
  One build slot: verify the egress ruleset, claim, run the job, repeat.

  The claim is a long poll, so an empty answer (204) claims again at once
  (but at most once a second, in case the portal answers early). Errors
  back off from 30 s, doubling up to 5 min, and reset after a good claim.
  Without a verified egress ruleset the slot claims nothing: it reports
  `egress: "missing"` through `/status` and backs off.
  """
  use GenServer

  require Logger

  alias NccAgent.{Client, Config, Identity, Job, Updater}

  @egress_module NccAgent.Egress
  @backoff_ms 30_000
  @max_backoff_ms 300_000
  @min_poll_ms 1_000

  def child_spec(n) do
    %{id: {__MODULE__, n}, start: {__MODULE__, :start_link, [n]}}
  end

  def start_link(n), do: GenServer.start_link(__MODULE__, n)

  @impl true
  def init(n) do
    send(self(), :tick)
    {:ok, %{n: n, backoff: @backoff_ms}}
  end

  @impl true
  def handle_info(:tick, state) do
    started = System.monotonic_time(:millisecond)

    case step() do
      :none ->
        elapsed = System.monotonic_time(:millisecond) - started
        Process.send_after(self(), :tick, max(@min_poll_ms - elapsed, 0))
        {:noreply, %{state | backoff: @backoff_ms}}

      :ran ->
        send(self(), :tick)
        {:noreply, %{state | backoff: @backoff_ms}}

      {:error, reason} ->
        Logger.warning(
          "slot #{state.n}: #{inspect(reason)}; retrying in #{div(state.backoff, 1000)} s"
        )

        Process.send_after(self(), :tick, state.backoff)
        {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff_ms)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp step do
    egress = if @egress_module.verify() == :ok, do: "ok", else: "missing"

    with {:ok, req} <- Identity.ensure() do
      if egress == "ok", do: claim(req), else: egress_missing(req)
    end
  end

  defp claim(req) do
    case Client.claim(req, 1, "ok") do
      :none -> :none
      {:ok, claim} -> run(req, claim)
      {:error, reason} -> {:error, reason}
    end
  end

  defp egress_missing(req) do
    _ = Client.status(req, "missing", 0)
    {:error, :egress_missing}
  end

  defp run(req, claim) do
    config = Config.get()

    case Updater.maybe_update(claim, config) do
      {:updating, version} ->
        # The VM is stopping; the lease goes back to the queue when it
        # times out, and the new release claims afresh.
        Logger.info("lease #{claim["lease_id"]} left to the agent #{version}")

      :ok ->
        case Job.run(req, claim, config) do
          {:ok, outcome} ->
            Logger.info("lease #{claim["lease_id"]} (#{claim["run_id"]}): #{outcome}")

          {:error, reason} ->
            Logger.error("lease #{claim["lease_id"]} (#{claim["run_id"]}): #{inspect(reason)}")
        end
    end

    :ran
  end
end
