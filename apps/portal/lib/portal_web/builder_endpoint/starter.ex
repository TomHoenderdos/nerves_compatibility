defmodule PortalWeb.BuilderEndpoint.Starter do
  @moduledoc """
  Starts `PortalWeb.BuilderEndpoint` (or any child spec) and, when its port is
  taken, keeps retrying instead of failing the boot.

  On the web host two releases overlap during a blue/green deploy
  (`ops/blue-green.sh`). The new one must serve the public site while the old
  one still holds the builder port, and must take the port over the moment the
  old one stops. The port is never shared: `Portal.Builders.Upload`
  serialises a lease's upload batches with a lock local to one node, which two
  listeners would split.

  Any start error other than a nested `:eaddrinuse` stops this process, so a
  broken endpoint still fails the boot as it did before. While waiting it
  warns once, then once per `warn_every_ms`: a port that never frees up is a
  condition an operator has to see. `status/1` shows the state on the admin
  Builders tab and in `/health`.
  """
  use GenServer
  require Logger

  @type status :: :off | :bound | {:waiting, DateTime.t()}

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`:bound`, `:off` (started without a listener) or `{:waiting, since}`."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :status), else: :off
  end

  @doc "True when a start error, however deeply wrapped, is a port in use."
  @spec eaddrinuse?(term()) :: boolean()
  def eaddrinuse?(:eaddrinuse), do: true
  def eaddrinuse?(t) when is_tuple(t), do: t |> Tuple.to_list() |> eaddrinuse?()
  def eaddrinuse?(l) when is_list(l), do: Enum.any?(l, &eaddrinuse?/1)
  def eaddrinuse?(%_{} = s), do: s |> Map.from_struct() |> eaddrinuse?()
  def eaddrinuse?(%{} = m), do: m |> Map.values() |> eaddrinuse?()
  def eaddrinuse?(s) when is_binary(s), do: String.contains?(s, "eaddrinuse")
  def eaddrinuse?(_), do: false

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      child: Keyword.fetch!(opts, :child),
      serving?: Keyword.get(opts, :serving?, fn -> true end),
      retry_ms: Keyword.get(opts, :retry_ms, 1_000),
      warn_every_ms: Keyword.get(opts, :warn_every_ms, 60_000),
      sup: nil,
      waiting_since: nil,
      warned_at: nil
    }

    case attempt(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, %{sup: nil} = state),
    do: {:reply, {:waiting, state.waiting_since}, state}

  def handle_call(:status, _from, state),
    do: {:reply, if(state.serving?.(), do: :bound, else: :off), state}

  @impl true
  def handle_info(:retry, state) do
    case attempt(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  # The endpoint's supervisor died after it was up: crash with it, so the
  # application supervisor restarts this process as it restarted the endpoint.
  def handle_info({:EXIT, sup, reason}, %{sup: sup} = state), do: {:stop, reason, state}
  # A failed `Supervisor.start_link/2` also sends its exit here; ignore it.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{sup: sup}) when is_pid(sup), do: Supervisor.stop(sup)
  def terminate(_reason, _state), do: :ok

  defp attempt(state) do
    case Supervisor.start_link([state.child], strategy: :one_for_one) do
      {:ok, sup} ->
        if state.waiting_since,
          do: Logger.info("builder endpoint bound (waited since #{state.waiting_since})")

        {:ok, %{state | sup: sup, waiting_since: nil, warned_at: nil}}

      {:error, reason} ->
        if eaddrinuse?(reason), do: {:ok, wait(state)}, else: {:error, reason}
    end
  end

  defp wait(state) do
    now = System.monotonic_time(:millisecond)
    since = state.waiting_since || DateTime.utc_now()

    warned_at =
      if is_nil(state.warned_at) or now - state.warned_at >= state.warn_every_ms do
        Logger.warning(
          "builder endpoint: port #{port(state.child)} is in use (waiting since #{since}); " <>
            "another release still holds it"
        )

        now
      else
        state.warned_at
      end

    Process.send_after(self(), :retry, state.retry_ms)
    %{state | waiting_since: since, warned_at: warned_at}
  end

  defp port(mod) when is_atom(mod) do
    config = Application.get_env(:portal, mod, [])
    get_in(config, [:https, :port]) || get_in(config, [:http, :port]) || "?"
  end

  defp port(_), do: "?"
end
