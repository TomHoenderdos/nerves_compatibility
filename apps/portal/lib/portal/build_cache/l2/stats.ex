defmodule Portal.BuildCache.L2.Stats do
  @moduledoc """
  Per-node counters, in-flight claims and bad-object marks for the L2 build
  cache, in one public named ETS table this process owns.

  Nothing here is durable and nothing here may break a build: every public
  function tolerates the table being absent (during a restart of this process)
  and answers with a neutral default. Rows are `{:counter, name}` (integer),
  `{:last, :upload | :download}` (unix ms), `{:claim, key}` (the holder pid)
  and `{:bad, key}` (unix ms until which the object is not fetched again).
  """
  use GenServer

  @table :ncc_build_cache_l2
  @events %{
    upload_ok: :uploads,
    upload_failed: :upload_failures,
    download_ok: :downloads,
    download_failed: :download_failures,
    refused: :refused,
    discarded: :discarded,
    list_failed: :list_failures
  }
  @counters Map.values(@events) ++ [:bytes_up, :bytes_down]

  @type event ::
          :upload_ok
          | :upload_failed
          | :download_ok
          | :download_failed
          | :refused
          | :discarded
          | :list_failed

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @spec record(event(), non_neg_integer()) :: :ok
  def record(event, bytes \\ 0) do
    safe(:ok, fn ->
      bump(Map.fetch!(@events, event), 1)
      now = System.system_time(:millisecond)

      case event do
        :upload_ok ->
          bump(:bytes_up, bytes)
          :ets.insert(@table, {{:last, :upload}, now})

        :download_ok ->
          bump(:bytes_down, bytes)
          :ets.insert(@table, {{:last, :download}, now})

        _ ->
          :ok
      end

      :ok
    end)
  end

  @spec snapshot() :: map()
  def snapshot do
    safe(empty_snapshot(), fn ->
      counters = Map.new(@counters, &{&1, counter(&1)})
      Map.merge(counters, %{last_upload: last(:upload), last_download: last(:download)})
    end)
  end

  @doc "Takes the in-flight claim on `key`; false when another live process holds it."
  @spec claim(String.t()) :: boolean()
  def claim(key) do
    safe(false, fn ->
      row = {{:claim, key}, self()}

      :ets.insert_new(@table, row) or
        (stale_claim?(key) and
           (:ets.delete(@table, {:claim, key}) and :ets.insert_new(@table, row)))
    end)
  end

  @spec release(String.t()) :: :ok
  def release(key) do
    safe(:ok, fn ->
      :ets.delete(@table, {:claim, key})
      :ok
    end)
  end

  @spec mark_bad(String.t()) :: :ok
  def mark_bad(key) do
    safe(:ok, fn ->
      :ets.insert(@table, {{:bad, key}, System.system_time(:millisecond) + :timer.hours(24)})
      :ok
    end)
  end

  @spec bad?(String.t(), integer()) :: boolean()
  def bad?(key, now_ms \\ System.system_time(:millisecond)) do
    safe(false, fn ->
      case :ets.lookup(@table, {:bad, key}) do
        [{_, until}] -> until > now_ms
        [] -> false
      end
    end)
  end

  @spec reset() :: :ok
  def reset do
    safe(:ok, fn ->
      :ets.delete_all_objects(@table)
      :ok
    end)
  end

  defp stale_claim?(key) do
    case :ets.lookup(@table, {:claim, key}) do
      [{_, pid}] -> not Process.alive?(pid)
      [] -> true
    end
  end

  defp counter(name) do
    case :ets.lookup(@table, {:counter, name}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  defp bump(name, by),
    do: :ets.update_counter(@table, {:counter, name}, by, {{:counter, name}, 0})

  defp last(which) do
    case :ets.lookup(@table, {:last, which}) do
      [{_, ms}] -> DateTime.from_unix!(ms, :millisecond)
      [] -> nil
    end
  end

  defp empty_snapshot do
    Map.new(@counters, &{&1, 0}) |> Map.merge(%{last_upload: nil, last_download: nil})
  end

  defp safe(default, fun) do
    fun.()
  rescue
    ArgumentError -> default
  end
end
