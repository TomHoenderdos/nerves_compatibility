defmodule Portal.RateLimiter do
  @moduledoc """
  Fixed-window request counters for the public site's costly endpoints: those
  that hash a password, call hex.pm or GitHub, or leave a row an admin has to
  review. `PortalWeb.Plugs.RateLimit` is the caller.

  The same design as `Portal.Builders.RateLimit`, which guards the builder
  API: a public ETS table, one `:ets.update_counter/4` per hit in the
  caller's own process, and this GenServer only owning the table and
  sweeping ended windows once a minute. It keeps its own table so the two
  endpoints' counters never meet.

  A fixed window lets a client through up to twice its limit across a
  window boundary. For "stop a flood" rather than "meter a quota" that is
  fine, and it keeps a hit to one ETS operation.

  ## Per node

  Counters live in this node's memory. Only the serving release receives
  public traffic, so on a host running two releases side by side the idle one
  counts nothing, and a switch between them starts every client from zero.

  ## Configuration

      config :portal, Portal.RateLimiter,
        enabled: true,
        limits: %{auth: {10, :timer.minutes(1)}}

  `:limits` maps a bucket to `{hits, window_ms}` and is merged over the
  defaults in `default_limits/0`. `enabled: false` turns every limit off;
  the test environment does that.
  """
  use GenServer

  @table :ncc_rate_limiter
  @minute :timer.minutes(1)

  @default_limits %{
    # Password hashing, TOTP and passkey checks: sign-in, sign-up, the second
    # factor, re-authentication and password changes share one budget. One
    # sign-in is a couple of hits, so ten a minute never stops a person.
    auth: {10, @minute},
    # Device flows started and polled against hex.pm and GitHub.
    provider_auth: {10, @minute},
    # Anonymous scan requests, each a row in the admin review queue.
    scan_request: {5, @minute},
    # The scan form's package typeahead, per client and for everyone at once:
    # it spends hex.pm's per-address quota, which the portal's own release
    # checks draw on too, and many clients each under their own limit would
    # still exhaust it together. The global budget counts only searches that
    # reach hex.pm, not those `Portal.HexSearchCache` answers.
    hex_search: {30, @minute},
    hex_search_global: {80, @minute},
    # Miss reports from the precompiled client (`mix precompiled.report`),
    # each a stored row: per client, and for everyone at once per hour and
    # per day, so many clients each under their own limit cannot fill the
    # table either. A retraction (DELETE) counts against the same buckets.
    precompiled_report: {10, :timer.hours(1)},
    precompiled_report_global: {300, :timer.hours(1)},
    precompiled_report_global_day: {2000, :timer.hours(24)}
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The built-in `{hits, window_ms}` per bucket."
  def default_limits, do: @default_limits

  @doc "Whether limits apply at all; see the moduledoc."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  The `{hits, window_ms}` of `bucket`: configured, else the default. Raises on
  a bucket that has neither, so a typo cannot pass as "unlimited".
  """
  @spec limit(atom()) :: {non_neg_integer(), pos_integer()}
  def limit(bucket) do
    @default_limits
    |> Map.merge(Map.new(Keyword.get(config(), :limits, %{})))
    |> Map.fetch!(bucket)
  end

  @doc """
  Count one hit for `key` in `bucket`.

  Returns `:ok` while the key is within `limit` hits per `window_ms`, and
  `{:error, retry_after_ms}`, the time left in the window, once it is over.
  `:now_ms` stands in for the clock.
  """
  @spec hit(term(), term(), non_neg_integer(), pos_integer(), keyword()) ::
          :ok | {:error, pos_integer()}
  def hit(bucket, key, limit, window_ms, opts \\ []) do
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    window = div(now, window_ms)
    # The third element is when the window ends, so the sweep is right for
    # any window length.
    ends = (window + 1) * window_ms
    counter = {{bucket, key}, window}
    count = :ets.update_counter(@table, counter, {2, 1}, {counter, 0, ends})

    if count <= limit, do: :ok, else: {:error, ends - now}
  end

  @doc """
  Whether one more hit for `key` in `bucket` would be within `limit`, without
  counting it: `:ok`, or `{:error, retry_after_ms}` as `hit/5` would answer.
  For a budget spent only on success, together with `hit/5` once the request
  has succeeded. Concurrent requests may all peek before any hits, so such a
  budget can be overrun by the requests in flight at once.
  """
  @spec peek(term(), term(), non_neg_integer(), pos_integer(), keyword()) ::
          :ok | {:error, pos_integer()}
  def peek(bucket, key, limit, window_ms, opts \\ []) do
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    window = div(now, window_ms)
    ends = (window + 1) * window_ms

    count =
      case :ets.lookup(@table, {{bucket, key}, window}) do
        [{_counter, count, _ends}] -> count
        [] -> 0
      end

    if count < limit, do: :ok, else: {:error, ends - now}
  end

  @doc false
  def reset, do: :ets.delete_all_objects(@table)

  @doc false
  # Drop every window that ended before `now_ms`.
  def sweep(now_ms),
    do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now_ms}], [true]}])

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

  defp schedule, do: Process.send_after(self(), :sweep, @minute)

  defp config, do: Application.get_env(:portal, __MODULE__, [])
end
