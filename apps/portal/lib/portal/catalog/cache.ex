defmodule Portal.Catalog.Cache do
  @moduledoc """
  Short-lived memo for the catalog's derived aggregates.

  The dashboard, stats and failure-cluster pages are all built by folding the
  same three tables in Elixir -- every package, its latest run, and every system
  result belonging to those runs. On 2026-09-11 that was 2,506 packages,
  2,575 runs and 9,463 system results, and `Portal.Catalog.dashboard/2`
  measured 655ms warm / 1850ms cold on production.

  A LiveView mounts twice: once to render the static HTML and again when the
  socket connects. Both mounts run `mount/3`, so every visitor paid that cost
  twice -- and the second one is exactly when Phoenix's `topbar` progress bar is
  on screen, which is the slow "loading bar" users see on first load.

  These aggregates are counts and rankings over completed builds. Builds arrive
  from scan requests, not on a schedule, and the queues are usually idle, so the
  numbers are unchanged between the two mounts of a single page view and almost
  always unchanged between page views. Recomputing them per mount buys nothing.

  ## Why a TTL rather than invalidation on ingest

  Ingestion happens on the build host; the dashboard is served from the web
  host. They are separate releases with no distribution between them
  (`Node.list()` is empty on both), so a PubSub broadcast from the ingesting
  node would never reach the node holding the stale entry. A TTL needs no
  coordination and is therefore correct on every node independently. The cost
  is bounded staleness, which for a build-results dashboard is not a cost.

  ## Behaviour

  * A fresh entry is served straight from ETS -- no GenServer call, so readers
    never contend with each other.
  * A stale entry is served immediately and a refresh runs in the background.
    Only the very first caller after a restart ever waits for a computation.
  * Concurrent callers for the same key share one computation. This is the part
    that matters under load: each computation holds a database connection and
    materialises ~9,500 rows, so a stampede of them is how a slow page becomes
    an outage.
  * `ttl_ms: 0` disables the cache completely and calls straight through. The
    test environment uses it, so tests observe their own writes and no state
    leaks between them through a shared ETS table.

  A computation that raises is not cached. The exception is re-raised in each
  waiting caller with its original stacktrace, leaving this process alive --
  a failing query must not take down the table and turn a slow page into a
  broken one.
  """

  use GenServer

  require Logger

  @table __MODULE__

  # Long enough that a burst of visitors shares one computation, short enough
  # that a newly ingested build shows up while someone is still looking at the
  # page that made them curious.
  @default_ttl_ms :timer.seconds(60)

  @doc """
  Return the cached value for `key`, computing it with `fun` when needed.

  `fun` must be a 0-arity function returning the value to cache. It may run in
  a different process than the caller, so it must not depend on caller process
  state (it must not, for example, rely on an Ecto sandbox connection owned by
  the calling test process -- which is the other reason the test environment
  sets `ttl_ms: 0`).
  """
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, fun) when is_function(fun, 0) do
    case ttl_ms() do
      0 ->
        fun.()

      ttl ->
        case lookup(key) do
          {:fresh, value} ->
            value

          {:stale, value} ->
            # `GenServer.cast/2` swallows a send to an unregistered name, so this
            # stays safe even if the cache is on its way down.
            GenServer.cast(__MODULE__, {:refresh, key, fun, ttl})
            value

          :miss ->
            unwrap(call_refresh(key, fun, ttl))

          # The table exists only once this process has started. Anything
          # reaching the catalog before then -- a release `eval` task, which
          # starts the repo but no applications -- computes rather than crashes.
          :no_table ->
            fun.()
        end
    end
  end

  defp call_refresh(key, fun, ttl) do
    GenServer.call(__MODULE__, {:fetch, key, fun, ttl}, :infinity)
  catch
    # Racing a shutdown. The scope here is deliberately just the call: catching
    # around `fun.()` as well would swallow a `:noproc` raised *by* the
    # computation and silently run it a second time.
    :exit, {:noproc, _} -> {:ok, fun.()}
    :exit, {:normal, _} -> {:ok, fun.()}
  end

  @doc "Drop every entry. Exposed for tests and for `bin/portal rpc`."
  def flush, do: GenServer.call(__MODULE__, :flush)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{inflight: %{}}}
  end

  @impl true
  def handle_call({:fetch, key, fun, ttl}, from, state) do
    # Re-check under the server: between this caller's miss and its call, another
    # caller may already have stored a value or started computing one.
    case lookup(key) do
      {:fresh, value} -> {:reply, {:ok, value}, state}
      _ -> {:noreply, start_or_join(state, key, fun, ttl, from)}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:refresh, key, fun, ttl}, state) do
    {:noreply, start_or_join(state, key, fun, ttl, nil)}
  end

  # A computation finished. Store it if it succeeded, and hand the outcome to
  # everyone who blocked on it.
  @impl true
  def handle_info({:result, pid, outcome}, state) do
    case pop_inflight(state, pid) do
      {nil, state} ->
        {:noreply, state}

      {{key, ttl, waiters, mon}, state} ->
        Process.demonitor(mon, [:flush])

        case outcome do
          {:ok, value} ->
            store(key, value, ttl)
            reply_all(waiters, {:ok, value})

          {:raised, kind, reason, stacktrace} ->
            Logger.warning("catalog cache refresh for #{inspect(key)} failed: #{inspect(reason)}")
            reply_all(waiters, {:raised, kind, reason, stacktrace})
        end

        {:noreply, state}
    end
  end

  # The computation died without reporting -- killed, or an exit that `try`
  # cannot catch. Waiters must not hang, so fail them explicitly; any stale
  # entry stays put and the next reader triggers a fresh attempt.
  @impl true
  def handle_info({:DOWN, _mon, :process, pid, reason}, state) do
    case pop_inflight(state, pid) do
      {nil, state} ->
        {:noreply, state}

      {{key, _ttl, waiters, _mon}, state} ->
        Logger.warning("catalog cache refresh for #{inspect(key)} died: #{inspect(reason)}")
        reply_all(waiters, {:raised, :exit, reason, []})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # One computation per key. A second caller for a key already being computed
  # joins the existing waiter list instead of starting a duplicate.
  defp start_or_join(state, key, fun, ttl, from) do
    case Enum.find(state.inflight, fn {_pid, {k, _ttl, _waiters, _mon}} -> k == key end) do
      {pid, {^key, ttl0, waiters, mon}} ->
        put_in(state.inflight[pid], {key, ttl0, add_waiter(waiters, from), mon})

      nil ->
        parent = self()

        # `spawn_monitor`, not `Task.async`: a Task is *linked*, so a
        # computation killed from outside would take this process -- and the
        # whole table -- down with it. Monitored and unlinked, the same kill
        # arrives as a `:DOWN` this process handles.
        {pid, mon} =
          spawn_monitor(fn ->
            outcome =
              try do
                {:ok, fun.()}
              catch
                kind, reason -> {:raised, kind, reason, __STACKTRACE__}
              end

            send(parent, {:result, self(), outcome})
          end)

        put_in(state.inflight[pid], {key, ttl, add_waiter([], from), mon})
    end
  end

  defp add_waiter(waiters, nil), do: waiters
  defp add_waiter(waiters, from), do: [from | waiters]

  defp pop_inflight(state, pid) do
    {entry, inflight} = Map.pop(state.inflight, pid)
    {entry, %{state | inflight: inflight}}
  end

  defp reply_all(waiters, outcome), do: Enum.each(waiters, &GenServer.reply(&1, outcome))

  defp unwrap({:ok, value}), do: value
  defp unwrap({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, fresh_until}] ->
        if now() < fresh_until, do: {:fresh, value}, else: {:stale, value}

      [] ->
        :miss
    end
  rescue
    # No such table -- the cache has not started. Narrower than a catch around
    # the whole fetch, which would also swallow an ArgumentError raised by the
    # cached computation and re-run it.
    ArgumentError -> :no_table
  end

  defp store(key, value, ttl), do: :ets.insert(@table, {key, value, now() + ttl})

  defp now, do: System.monotonic_time(:millisecond)

  defp ttl_ms do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
