defmodule Portal.Builders.RateLimit do
  @moduledoc """
  Fixed-window counters in a public ETS table: enrolment 10/min per address,
  claims 60/min per builder. Callers count in their own process through
  `:ets.update_counter/4`; this GenServer only owns the table and sweeps
  windows that have ended once a minute.
  """
  use GenServer

  @table :ncc_builder_rate_limit

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Count one call against `key` and say whether it is within `limit` per `window_ms`."
  @spec allow?(term(), pos_integer(), pos_integer(), keyword()) :: boolean()
  def allow?(key, limit, window_ms, opts \\ []) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    window = div(now, window_ms)
    # The third element is when the window ends, so the sweep is right for
    # any window length.
    ends = (window + 1) * window_ms
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, ends})
    count <= limit
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))
    schedule()
    {:noreply, state}
  end

  @doc false
  # Drop every window that ended before `now_ms`.
  def sweep(now_ms),
    do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now_ms}], [true]}])

  defp schedule, do: Process.send_after(self(), :sweep, :timer.minutes(1))
end
