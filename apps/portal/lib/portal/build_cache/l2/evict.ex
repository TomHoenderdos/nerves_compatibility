defmodule Portal.BuildCache.L2.Evict do
  @moduledoc """
  Keeps the L2 bucket under its size mark (`Config.max_bytes`), so that a
  store with a hard quota keeps accepting uploads.

  `run/2` lists the whole bucket and sums the sizes of every object in it,
  each key counted once. Above the high mark (90 % of `max_bytes`) it
  deletes objects oldest first (by `LastModified`, ties by key) until the
  total is at or below the low mark (75 %). Only cache entries are ever
  deleted: keys of the form `<slug>/<64 hex>.tar.gz` with a shareable slug
  (`Portal.BuildCache.L2.shareable_slug?/1`). Anything else in the bucket
  counts toward the total but stays; when those objects alone exceed the low
  mark, the run deletes nothing and warns, since emptying the cache could not
  bring the bucket down. Age is the upload
  time: an entry many builds restore is as old as one nobody uses, since S3
  keeps no read times. A deleted entry costs one rebuild on the next host
  that needs it, which then uploads it again.

  A run is bounded: at most `default_budget_ms/0` (listing included) and
  `default_max_deletes/0` deletes, and it ends at the first delete that
  fails, since a store refusing one will likely refuse the next. A listing
  reads at most 200 pages of 1000 keys; one cut there is warned about, its
  total is short, and the oldest-first ranking is over the listed part only
  (S3 lists in key order, not by age), so the run may evict less than it
  should and not the bucket's oldest objects.

  Nothing here raises: every failure ends the run with a summary saying why
  (`stopped`). Two hosts evicting at once is harmless, a DELETE of a deleted
  key is a success.

  `run/2` does nothing (and asks the store nothing) for a read-only config or
  one with no `max_bytes`.
  """
  require Logger

  alias Portal.BuildCache.L2
  alias Portal.BuildCache.L2.{Bounded, Client, Config, Stats}

  @default_budget_ms 120_000
  @default_max_deletes 5_000
  @max_pages 200
  @delete_timeout_ms 30_000
  @entry ~r/\A([^\/]+)\/[0-9a-f]{64}\.tar\.gz\z/

  @type summary :: %{
          listed: non_neg_integer(),
          total_bytes: non_neg_integer(),
          deleted: non_neg_integer(),
          freed_bytes: non_neg_integer(),
          stopped:
            nil
            | :budget
            | :max_deletes
            | {:unevictable, non_neg_integer()}
            | {:delete_failed | :list_failed, term()}
        }

  @spec default_budget_ms() :: pos_integer()
  def default_budget_ms, do: @default_budget_ms

  @spec default_max_deletes() :: pos_integer()
  def default_max_deletes, do: @default_max_deletes

  @doc """
  Evicts down to the low mark (see the moduledoc). Options: `:budget_ms`
  (#{@default_budget_ms}), `:max_deletes` (#{@default_max_deletes}) and
  `:clock`, a `fn -> ms end` read at the start and before every delete
  (default monotonic time); `:max_pages` (200) and `:max_keys` (1000) shape
  the listing.
  """
  @spec run(Config.t() | term(), keyword()) :: summary()
  def run(cfg, opts \\ [])

  def run(%Config{read_only?: false, max_bytes: max} = cfg, opts)
      when is_integer(max) and max > 0 do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    budget = Keyword.get(opts, :budget_ms, @default_budget_ms)
    deadline = clock.() + budget

    ctx = %{
      cfg: cfg,
      clock: clock,
      deadline: deadline,
      max_deletes: Keyword.get(opts, :max_deletes, @default_max_deletes),
      low: div(max * 3, 4)
    }

    cfg
    |> list(budget, Keyword.get(opts, :max_pages, @max_pages), Keyword.get(opts, :max_keys, 1000))
    |> evict(max, ctx)
    |> report(cfg)
  rescue
    e -> report(%{empty() | stopped: {:exception, Exception.message(e)}}, cfg)
  catch
    kind, reason -> report(%{empty() | stopped: {kind, reason}}, cfg)
  end

  def run(_cfg, _opts), do: empty()

  defp empty, do: %{listed: 0, total_bytes: 0, deleted: 0, freed_bytes: 0, stopped: nil}

  # The listing runs in a process of its own so that a store answering every
  # page slowly cannot hold the run past its budget.
  defp list(cfg, budget, max_pages, max_keys) do
    case Bounded.run(
           fn -> Client.list_all(cfg, "", max_pages: max_pages, max_keys: max_keys) end,
           timeout_ms: budget
         ) do
      {:ok, {:ok, objects, truncated?}} ->
        if truncated? do
          Logger.warning(
            "Build cache L2 eviction: the bucket listing stopped at #{max_pages} pages; " <>
              "the total is short and only the listed objects are ranked"
          )
        end

        {:ok, objects}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evict({:error, reason}, _max, _ctx) do
    Stats.record(:evict_list_failed)
    %{empty() | stopped: {:list_failed, reason}}
  end

  defp evict({:ok, objects}, max, ctx) do
    # A store that repeats keys across pages must not inflate the total.
    objects = Enum.uniq_by(objects, & &1.key)
    total = objects |> Enum.map(& &1.size) |> Enum.sum()
    summary = %{empty() | listed: length(objects), total_bytes: total}

    # Above 90 %: total / max > 9 / 10, in integers.
    if total * 10 > max * 9 do
      {entries, others} = Enum.split_with(objects, &entry?(&1.key))
      kept = others |> Enum.map(& &1.size) |> Enum.sum()

      if kept > ctx.low do
        Logger.warning(
          "Build cache L2 eviction in #{ctx.cfg.bucket}: #{kept} bytes of objects outside " <>
            "the cache layout exceed the low mark of #{ctx.low} bytes; nothing deleted"
        )

        %{summary | stopped: {:unevictable, kept}}
      else
        entries
        |> Enum.sort_by(&{DateTime.to_unix(&1.last_modified, :microsecond), &1.key})
        |> delete_oldest(total, summary, ctx)
      end
    else
      summary
    end
  end

  defp entry?(key) do
    case Regex.run(@entry, key) do
      [_, slug] -> L2.shareable_slug?(slug)
      nil -> false
    end
  end

  defp delete_oldest(_objects, total, summary, %{low: low}) when total <= low, do: summary
  defp delete_oldest([], _total, summary, _ctx), do: summary

  defp delete_oldest(_objects, _total, %{deleted: n} = summary, %{max_deletes: n}),
    do: %{summary | stopped: :max_deletes}

  defp delete_oldest([object | rest], total, summary, ctx) do
    remaining = ctx.deadline - ctx.clock.()

    if remaining <= 0 do
      %{summary | stopped: :budget}
    else
      timeout = min(remaining, @delete_timeout_ms)

      case Client.delete(ctx.cfg, object.key, timeout_ms: timeout) do
        :ok ->
          Stats.record(:evicted, object.size)

          summary = %{
            summary
            | deleted: summary.deleted + 1,
              freed_bytes: summary.freed_bytes + object.size
          }

          delete_oldest(rest, total - object.size, summary, ctx)

        {:error, reason} ->
          %{summary | stopped: {:delete_failed, reason}}
      end
    end
  end

  defp report(%{stopped: {:list_failed, reason}} = summary, _cfg) do
    Logger.warning("Build cache L2 eviction: the bucket listing failed: #{show(reason)}")
    summary
  end

  defp report(%{deleted: 0, stopped: nil} = summary, _cfg), do: summary

  defp report(summary, cfg) do
    stopped = if summary.stopped, do: "; stopped: #{show(summary.stopped)}", else: ""

    Logger.info(
      "Build cache L2 eviction in #{cfg.bucket}: listed #{summary.listed} objects, " <>
        "#{summary.total_bytes} bytes; deleted #{summary.deleted}, " <>
        "#{summary.freed_bytes} bytes#{stopped}"
    )

    summary
  end

  defp show(term), do: inspect(term, printable_limit: 200)
end
