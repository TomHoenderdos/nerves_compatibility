defmodule Portal.Oban.NodeSweep do
  @moduledoc """
  Oban plugin that queues this node's own `Portal.Workers.Sweep` once an
  hour, on the node's own queue (`Portal.NodeQueue`).

  `Oban.Plugins.Cron` inserts on the leader only, and its row carries one
  queue for every node. While the sweep's queue was the shared `:ingest`
  one, each hour's sweep ran on whichever builder fetched it first, and the
  other builders' disks went unswept. Every disk wants its own sweep, so
  every node schedules its own here. The plugin starts on every node, and
  stays only where the node queue runs: a node without one (the web host,
  which has no scratch root or build caches) starts nothing.

  The alternative was the leader's cron fanning one sweep out per known
  builder. The builders are not clustered, so the leader would have to learn
  them from the database, and a builder missing from what it learned would
  never be swept and never say so. Here a node that runs builds schedules
  its own sweep for as long as it runs.

  Each tick is at `:minute` past the hour (default 23, the old cron entry's),
  recomputed from the wall clock so it never drifts. The sweep is unique per
  queue over its incomplete states, so a tick that finds the last one still
  outstanding (a slow sweep, a queue paused by a deploy, a sweep stranded
  `executing` by a node that died under it, until Lifeline discards it)
  queues nothing, and says so in a warning naming that job. A failed insert
  is logged as an error, and the next tick tries again.

  For one release, each tick also cancels a sweep left on the shared
  `:ingest` queue (`Portal.NodeQueue`, "From the previous release"): a node
  still on the previous release can be the leader, and its cron puts its
  sweep there, which no node of this release runs. A node still on the
  previous release runs `:ingest` and claims such a row in seconds, so only
  one unclaimed for two hours goes.
  """

  @behaviour Oban.Plugin

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Oban.Job
  alias Portal.NodeQueue
  alias Portal.Workers.Sweep

  @default_minute 23
  @legacy_queue "ingest"
  @legacy_after_s 2 * 3600

  @impl Oban.Plugin
  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    queue = Keyword.get_lazy(opts, :queue, &NodeQueue.name/0)

    if runs_queue?(conf, queue) do
      state = %{
        oban: conf.name,
        queue: queue,
        minute: Keyword.get(opts, :minute, @default_minute)
      }

      GenServer.start_link(__MODULE__, state, name: opts[:name])
    else
      :ignore
    end
  end

  @impl Oban.Plugin
  def validate(opts) do
    Enum.reduce_while(opts, :ok, fn
      {:conf, _conf}, :ok -> {:cont, :ok}
      {:name, _name}, :ok -> {:cont, :ok}
      {:queue, queue}, :ok when is_binary(queue) -> {:cont, :ok}
      {:minute, minute}, :ok when minute in 0..59 -> {:cont, :ok}
      {key, value}, :ok -> {:halt, {:error, "invalid #{key}: #{inspect(value)}"}}
    end)
  end

  @impl GenServer
  def init(state), do: {:ok, schedule(state, nil)}

  @impl GenServer
  def handle_info(:tick, state) do
    tick(state.oban, state.queue)
    {:noreply, schedule(state, state.at)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Queues this hour's sweep on `queue` through the Oban instance `oban`, and
  cancels the previous release's sweeps left on the shared queue. Always
  `:ok`: what went wrong is logged, and the next tick tries again.
  """
  @spec tick(Oban.name(), String.t()) :: :ok
  def tick(oban, queue) do
    queue_sweep(oban, queue)
    cancel_legacy(oban)
  end

  @doc """
  Milliseconds from `now` to the next `minute` past the hour after both `now`
  and `last`, the time the tick that just ran was aimed at (nil before the
  first). The timer runs on monotonic time and the target is on the wall
  clock, so a wall clock stepped back fires a tick early: counted from `now`
  alone, the next one would come seconds later, for the same hour.
  """
  @spec next_tick_ms(DateTime.t(), 0..59, DateTime.t() | nil) :: non_neg_integer()
  def next_tick_ms(%DateTime{} = now, minute, last \\ nil),
    do: DateTime.diff(next_tick(now, minute, last), now, :millisecond)

  defp next_tick(now, minute, last) do
    from = if last != nil and DateTime.compare(last, now) == :gt, do: last, else: now
    at = %{from | minute: minute, second: 0, microsecond: {0, 0}}
    if DateTime.compare(at, from) == :gt, do: at, else: DateTime.add(at, 3600, :second)
  end

  defp schedule(state, last) do
    now = DateTime.utc_now()
    at = next_tick(now, state.minute, last)
    Process.send_after(self(), :tick, DateTime.diff(at, now, :millisecond))
    Map.put(state, :at, at)
  end

  defp runs_queue?(conf, queue),
    do: Enum.any?(conf.queues, fn {name, _opts} -> to_string(name) == queue end)

  defp queue_sweep(oban, queue) do
    case Oban.insert(oban, Sweep.new(%{}, queue: queue)) do
      {:ok, %Job{conflict?: true} = last} ->
        Logger.warning(
          "#{queue}: no sweep queued this hour, the last one (job #{last.id}) " <>
            "is still #{last.state}"
        )

      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("#{queue}: could not queue this hour's sweep: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.error("#{queue}: could not queue this hour's sweep: #{Exception.message(exception)}")
  end

  defp cancel_legacy(oban) do
    cutoff = DateTime.add(DateTime.utc_now(), -@legacy_after_s, :second)

    query =
      from(j in Job,
        where: j.queue == @legacy_queue,
        where: j.worker == "Portal.Workers.Sweep",
        where: j.state in ["available", "scheduled"],
        where: j.scheduled_at < ^cutoff
      )

    case Oban.cancel_all_jobs(oban, query) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("cancelled #{count} sweep(s) left unclaimed on the shared ingest queue")
    end
  rescue
    exception ->
      Logger.error(
        "could not cancel the sweeps left on the shared ingest queue: " <>
          Exception.message(exception)
      )
  end
end
