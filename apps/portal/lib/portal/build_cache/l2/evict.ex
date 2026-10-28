defmodule Portal.BuildCache.L2.Evict do
  @moduledoc """
  Keeps the L2 bucket under its size mark (`Config.max_bytes`), so that a
  store with a hard quota keeps accepting uploads.

  `run/2` lists the whole bucket and sums the sizes. Above the high mark (90 %
  of `max_bytes`) it deletes objects oldest first (by `LastModified`, ties by
  key) until the total is at or below the low mark (75 %). Age is the upload
  time: an entry many builds restore is as old as one nobody uses, since S3
  keeps no read times. A deleted entry costs one rebuild on the next host
  that needs it, which then uploads it again.

  A run is bounded: at most `default_budget_ms/0` (listing included) and
  `default_max_deletes/0` deletes, and it ends at the first delete that
  fails, since a store refusing one will likely refuse the next. A listing
  reads at most 200 pages of 1000 keys; past that the total is short and the
  run evicts less than it would, never more.

  Nothing here raises: every failure ends the run with a summary saying why
  (`stopped`). Two hosts evicting at once is harmless, a DELETE of a deleted
  key is a success.

  `run/2` does nothing (and asks the store nothing) for a read-only config or
  one with no `max_bytes`.
  """
  require Logger

  alias Portal.BuildCache.L2.{Bounded, Client, Config, Stats}

  @default_budget_ms 120_000
  @default_max_deletes 5_000
  @max_pages 200
  @delete_timeout_ms 30_000

  @type summary :: %{
          listed: non_neg_integer(),
          total_bytes: non_neg_integer(),
          deleted: non_neg_integer(),
          freed_bytes: non_neg_integer(),
          stopped: nil | :budget | :max_deletes | {:delete_failed | :list_failed, term()}
        }

  @spec default_budget_ms() :: pos_integer()
  def default_budget_ms, do: @default_budget_ms

  @spec default_max_deletes() :: pos_integer()
  def default_max_deletes, do: @default_max_deletes

  @doc """
  Evicts down to the low mark (see the moduledoc). Options: `:budget_ms`
  (#{@default_budget_ms}), `:max_deletes` (#{@default_max_deletes}) and
  `:clock`, a `fn -> ms end` read at the start and before every delete
  (default monotonic time).
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
    |> list(budget)
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
  defp list(cfg, budget) do
    case Bounded.run(fn -> Client.list(cfg, "", max_pages: @max_pages) end,
           timeout_ms: budget
         ) do
      {:ok, {:ok, objects}} -> {:ok, objects}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evict({:error, reason}, _max, _ctx) do
    Stats.record(:list_failed)
    %{empty() | stopped: {:list_failed, reason}}
  end

  defp evict({:ok, objects}, max, ctx) do
    total = objects |> Enum.map(& &1.size) |> Enum.sum()
    summary = %{empty() | listed: length(objects), total_bytes: total}

    # Above 90 %: total / max > 9 / 10, in integers.
    if total * 10 > max * 9 do
      objects
      |> Enum.sort_by(&{DateTime.to_unix(&1.last_modified, :microsecond), &1.key})
      |> delete_oldest(total, summary, ctx)
    else
      summary
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
