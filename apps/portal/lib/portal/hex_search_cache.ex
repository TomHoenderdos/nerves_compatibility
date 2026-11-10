defmodule Portal.HexSearchCache do
  @moduledoc """
  Recent answers of the scan form's hex.pm package search, per query, so a
  query many people type costs hex.pm one request every few minutes rather
  than one per keystroke per visitor. `PortalWeb.PageController` counts a
  search against the global hex search budget only when it misses here.

  A public ETS table read and written in the caller's process; this
  GenServer only owns it and drops expired entries once a minute. The table
  holds at most `@max_entries` queries: once full, new answers are served but
  not stored until the sweep makes room. Only successful answers are stored,
  so a hex.pm outage is not remembered.

  Per node, like `Portal.RateLimiter`.
  """
  use GenServer

  @table :ncc_hex_search_cache
  @ttl_ms :timer.minutes(5)
  @max_entries 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The key a query is stored under: trimmed and lower-cased."
  @spec normalize(String.t()) :: String.t()
  def normalize(query), do: query |> String.trim() |> String.downcase()

  @doc "The stored answer for `query`, unless it is older than five minutes."
  @spec fetch(String.t(), keyword()) :: {:ok, list()} | :miss
  def fetch(query, opts \\ []) do
    now = now(opts)

    case :ets.lookup(@table, normalize(query)) do
      [{_, packages, expires}] when expires > now -> {:ok, packages}
      _ -> :miss
    end
  end

  @doc "Store `packages` as the answer for `query`, unless the table is full."
  @spec put(String.t(), list(), keyword()) :: :ok
  def put(query, packages, opts \\ []) do
    if :ets.info(@table, :size) < Keyword.get(opts, :max_entries, @max_entries) do
      :ets.insert(@table, {normalize(query), packages, now(opts) + @ttl_ms})
    end

    :ok
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @doc false
  # Drop every entry that expired by `now_ms`.
  def sweep(now_ms),
    do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now_ms}], [true]}])

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, :timer.minutes(1))

  defp now(opts),
    do: Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
end
