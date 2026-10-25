defmodule NccAgent.Heartbeat do
  @moduledoc """
  Keeps a job's lease alive: posts the phase and the runner log's tail at
  start, on every phase change and every 60 s, until the job stops it. A
  failed heartbeat is logged; the portal reaps a lease that goes quiet.
  """
  use GenServer

  require Logger

  alias NccAgent.{Client, Docker}

  @interval 60_000

  @type opts :: %{
          required(:req) => Req.Request.t(),
          required(:lease_id) => String.t(),
          required(:log_path) => Path.t(),
          optional(:phase) => String.t(),
          optional(:interval) => pos_integer()
        }

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Switches the phase and heartbeats it right away."
  @spec set_phase(pid(), String.t()) :: :ok
  def set_phase(pid, phase) when phase in ~w(pulling building uploading),
    do: GenServer.cast(pid, {:phase, phase})

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    state =
      opts
      |> Map.put_new(:phase, "pulling")
      |> Map.put_new(:interval, @interval)
      |> Map.put(:timer, nil)

    {:ok, state, {:continue, :beat}}
  end

  @impl true
  def handle_continue(:beat, state), do: {:noreply, beat(state)}

  @impl true
  def handle_cast({:phase, phase}, %{phase: phase} = state), do: {:noreply, state}
  def handle_cast({:phase, phase}, state), do: {:noreply, beat(%{state | phase: phase})}

  @impl true
  def handle_info(:beat, state), do: {:noreply, beat(state)}

  defp beat(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    try do
      case Client.heartbeat(state.req, state.lease_id, state.phase, tail(state)) do
        :ok -> :ok
        {:error, reason} -> failed(state, inspect(reason))
      end
    rescue
      # Linked to the job: a heartbeat must never take the build down.
      e -> failed(state, Exception.message(e))
    end

    %{state | timer: Process.send_after(self(), :beat, state.interval)}
  end

  defp tail(state), do: Docker.log_tail(state.log_path)

  defp failed(state, why), do: Logger.warning("heartbeat for #{state.lease_id} failed: #{why}")
end
