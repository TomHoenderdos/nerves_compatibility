defmodule Orchestrator.Queue do
  @moduledoc """
  A durable queue backed by DETS for storing package/version pairs to be processed.

  The queue maintains two DETS tables:
  - `queue`: Pending package/versions to check
  - `checked`: Package/versions that have been checked (acts as deduplication set)

  Both tables are persisted to disk and survive restarts.
  """

  use GenServer
  require Logger

  @type package_version :: {package :: String.t(), version :: String.t()}
  @type priority :: :hex_owner | :github_repo | :anonymous | :normal | :pending_review
  @type queue_entry :: %{
          counter: non_neg_integer(),
          priority: priority(),
          source: atom(),
          requested_at: DateTime.t()
        }

  ## Client API

  @doc """
  Starts the queue GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a package/version pair if it hasn't been checked yet.

  Returns:
  - `:ok` if enqueued
  - `{:already_checked, timestamp}` if already checked
  """
  @spec enqueue(package_version(), keyword()) :: :ok | {:already_checked, DateTime.t()}
  def enqueue({package, version} = item, opts \\ [])
      when is_binary(package) and is_binary(version) do
    GenServer.call(__MODULE__, {:enqueue, item, opts})
  end

  @doc """
  Queues an owner or human-checked rescan ahead of normal Hex polling work.

  Unlike `enqueue/2`, this may requeue an already checked package/version.
  """
  @spec request_rescan(package_version(), keyword()) :: :ok
  def request_rescan({package, version} = item, opts \\ [])
      when is_binary(package) and is_binary(version) do
    opts =
      opts
      |> Keyword.put_new(:allow_checked?, true)
      |> Keyword.put_new(:priority, :anonymous)

    GenServer.call(__MODULE__, {:enqueue, item, opts})
  end

  @doc """
  Dequeues the next package/version pair from the queue.

  Returns:
  - `{:ok, {package, version}}` if an item is available
  - `:empty` if the queue is empty
  """
  @spec dequeue() :: {:ok, package_version()} | :empty
  def dequeue() do
    GenServer.call(__MODULE__, :dequeue)
  end

  @doc """
  Marks a package/version as checked with the current timestamp.
  """
  @spec mark_checked(package_version()) :: :ok
  def mark_checked({package, version} = item) when is_binary(package) and is_binary(version) do
    GenServer.call(__MODULE__, {:mark_checked, item})
  end

  @doc """
  Returns whether a package/version has been checked.

  Returns:
  - `{:checked, timestamp}` if checked
  - `:not_checked` if not checked
  """
  @spec checked?(package_version()) :: {:checked, DateTime.t()} | :not_checked
  def checked?({package, version} = item) when is_binary(package) and is_binary(version) do
    GenServer.call(__MODULE__, {:checked?, item})
  end

  @doc """
  Returns the current queue size.
  """
  @spec size() :: non_neg_integer()
  def size() do
    GenServer.call(__MODULE__, :size)
  end

  @doc """
  Returns statistics about the queue.
  """
  @spec stats() :: %{
          queue_size: non_neg_integer(),
          checked_count: non_neg_integer(),
          next_item: package_version() | nil
        }
  def stats() do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns all items in the queue (for inspection).
  """
  @spec list() :: [package_version()]
  def list() do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Returns all queue entries with priority metadata.
  """
  @spec list_entries() :: [{package_version(), queue_entry()}]
  def list_entries() do
    GenServer.call(__MODULE__, :list_entries)
  end

  @doc """
  Returns recent checked items (up to limit).
  """
  @spec recent_checked(non_neg_integer()) :: [{package_version(), DateTime.t()}]
  def recent_checked(limit \\ 10) do
    GenServer.call(__MODULE__, {:recent_checked, limit})
  end

  @doc """
  Clears all checked items (use with caution).
  """
  @spec clear_checked() :: :ok
  def clear_checked() do
    GenServer.call(__MODULE__, :clear_checked)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    queue_file = Orchestrator.queue_file()
    checked_file = Orchestrator.checked_file()

    Logger.info("Opening queue database: #{queue_file}")
    Logger.info("Opening checked database: #{checked_file}")

    # Ensure parent directories exist
    File.mkdir_p!(Path.dirname(queue_file))
    File.mkdir_p!(Path.dirname(checked_file))

    # Open DETS tables
    {:ok, queue_table} = :dets.open_file(:queue, type: :set, file: String.to_charlist(queue_file))

    {:ok, checked_table} =
      :dets.open_file(:checked, type: :set, file: String.to_charlist(checked_file))

    state = %{
      queue: queue_table,
      checked: checked_table,
      # Counter for maintaining insertion order
      counter: get_max_counter(queue_table)
    }

    queue_size = :dets.info(queue_table, :size)
    checked_count = :dets.info(checked_table, :size)

    Logger.info("Queue initialized: #{queue_size} pending, #{checked_count} checked")

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, {package, version} = item, opts}, _from, state) do
    allow_checked? = Keyword.get(opts, :allow_checked?, false)

    case :dets.lookup(state.checked, item) do
      [{^item, timestamp}] when not allow_checked? ->
        {:reply, {:already_checked, timestamp}, state}

      _ ->
        # Check if already in queue
        case :dets.lookup(state.queue, item) do
          [{^item, stored}] ->
            existing_entry = normalize_entry(stored)
            requested_entry = build_entry(existing_entry.counter, opts)
            entry = higher_priority_entry(existing_entry, requested_entry)
            :dets.insert(state.queue, {item, entry})

            Logger.debug("Updated queued item: #{package}:#{version} priority=#{entry.priority}")
            {:reply, :ok, state}

          [] ->
            # Add to queue with counter for ordering
            new_counter = state.counter + 1
            entry = build_entry(new_counter, opts)
            :dets.insert(state.queue, {item, entry})
            Logger.debug("Enqueued: #{package}:#{version} priority=#{entry.priority}")
            {:reply, :ok, %{state | counter: new_counter}}
        end
    end
  end

  @impl true
  def handle_call(:dequeue, _from, state) do
    case find_oldest_item(state.queue) do
      nil ->
        {:reply, :empty, state}

      {item, _entry} ->
        :dets.delete(state.queue, item)
        {:reply, {:ok, item}, state}
    end
  end

  @impl true
  def handle_call({:mark_checked, item}, _from, state) do
    timestamp = DateTime.utc_now()
    :dets.insert(state.checked, {item, timestamp})
    :dets.delete(state.queue, item)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:checked?, item}, _from, state) do
    case :dets.lookup(state.checked, item) do
      [{^item, timestamp}] -> {:reply, {:checked, timestamp}, state}
      [] -> {:reply, :not_checked, state}
    end
  end

  @impl true
  def handle_call(:size, _from, state) do
    size = :dets.info(state.queue, :size)
    {:reply, size, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    queue_size = :dets.info(state.queue, :size)
    checked_count = :dets.info(state.checked, :size)

    next_item =
      case find_oldest_item(state.queue) do
        nil -> nil
        {item, _entry} -> item
      end

    stats = %{
      queue_size: queue_size,
      checked_count: checked_count,
      next_item: next_item
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    items =
      :dets.match(state.queue, {:"$1", :"$2"})
      |> sort_queue_rows()
      |> Enum.map(fn [item, _entry] -> item end)

    {:reply, items, state}
  end

  @impl true
  def handle_call(:list_entries, _from, state) do
    entries =
      :dets.match(state.queue, {:"$1", :"$2"})
      |> sort_queue_rows()
      |> Enum.map(fn [item, entry] -> {item, normalize_entry(entry)} end)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:recent_checked, limit}, _from, state) do
    items =
      :dets.match(state.checked, {:"$1", :"$2"})
      |> Enum.sort_by(fn [_item, timestamp] -> timestamp end, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(fn [item, timestamp] -> {item, timestamp} end)

    {:reply, items, state}
  end

  @impl true
  def handle_call(:clear_checked, _from, state) do
    :dets.delete_all_objects(state.checked)
    Logger.warning("Cleared all checked items")
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.queue)
    :dets.close(state.checked)
    :ok
  end

  ## Private Helpers

  defp get_max_counter(table) do
    :dets.match(table, {:"$1", :"$2"})
    |> Enum.map(fn [_item, entry] -> normalize_entry(entry).counter end)
    |> Enum.max(fn -> 0 end)
  end

  defp find_oldest_item(table) do
    :dets.match(table, {:"$1", :"$2"})
    |> sort_queue_rows()
    |> List.first()
    |> case do
      nil -> nil
      [item, entry] -> {item, normalize_entry(entry)}
    end
  end

  defp sort_queue_rows(rows) do
    Enum.sort_by(rows, fn [_item, entry] ->
      entry = normalize_entry(entry)
      {priority_rank(entry.priority), entry.counter}
    end)
  end

  defp build_entry(counter, opts) do
    %{
      counter: counter,
      priority: Keyword.get(opts, :priority, :normal),
      source: Keyword.get(opts, :source, :hex_poll),
      requested_at: Keyword.get(opts, :requested_at, DateTime.utc_now())
    }
  end

  defp normalize_entry(counter) when is_integer(counter) do
    %{counter: counter, priority: :normal, source: :hex_poll, requested_at: DateTime.utc_now()}
  end

  defp normalize_entry(entry) when is_map(entry) do
    %{
      counter: Map.fetch!(entry, :counter),
      priority: Map.get(entry, :priority, :normal),
      source: Map.get(entry, :source, :hex_poll),
      requested_at: Map.get(entry, :requested_at, DateTime.utc_now())
    }
  end

  defp higher_priority_entry(existing, requested) do
    if priority_rank(requested.priority) < priority_rank(existing.priority) do
      requested
    else
      existing
    end
  end

  defp priority_rank(:hex_owner), do: 0
  defp priority_rank(:github_repo), do: 10
  defp priority_rank(:anonymous), do: 50
  defp priority_rank(:normal), do: 100
  defp priority_rank(:pending_review), do: 200
  defp priority_rank(_), do: 100
end
