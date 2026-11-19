defmodule Portal.Toolchains.MemoryRouting do
  @moduledoc """
  Which Oban queue a `Portal.Workers.ToolchainBuild` goes on: `:toolchain`,
  or `:toolchain_big` for a package that needs more memory than a toolchain
  slot has.

  Most toolchain builds peak well under 1 GB, but a few dozen packages
  compile large data into their beams (country tables, Unicode data, big
  generated API clients) and are OOM-killed at a toolchain slot's limit, or
  end close to it and thrash for an hour without being killed. The memory
  record (`Portal.Catalog.RunMemory`) shows which ones: a package is big
  when any toolchain run of it in the last `window_days/0` days was
  OOM-killed, or peaked (`peak_used_bytes`) at `near_limit/0` of its limit
  or more. It is keyed on the package alone, across versions, variants and
  toolchains: a package that compiles big data does so in every version.

  `:toolchain_big` runs only on the hosts that list it in `OBAN_QUEUES`, with
  `NCC_TOOLCHAIN_BIG_MEMORY` per container (`Portal.Builder.toolchain_big_memory/0`).
  A job sent there while no node runs it would wait forever, so nothing goes
  there unless `live?/0`: some node's producer for the queue reported in the
  last 30 seconds (`Oban.Met.checks/0`, which every node replicates from
  every other over the Oban notifier). A paused producer counts, since a
  builder deploy pauses its queues and resumes them. While none is live,
  every job stays on `:toolchain` and an OOM retries there at the build limit,
  as before this queue existed; `rescue_stranded/1` moves back what waits on
  `:toolchain_big` once its hosts are gone.
  """

  import Ecto.Query

  require Logger

  alias Portal.Repo

  @big :toolchain_big
  @window_days 30
  # Percent of the limit.
  @near_limit 85
  @queued_states ~w(available scheduled retryable)
  # How long a job may wait on `:toolchain_big` without a live producer
  # before `rescue_stranded/1` moves it back. Longer than a builder restart,
  # so a deploy does not send its big jobs back to the small slots.
  @stranded_after_seconds 30 * 60

  @doc """
  This node's Oban config, without `:toolchain_big` when
  `Portal.Builder.check_toolchain_big_memory/1` refuses it: a node whose
  big slot is no bigger than its toolchain slot does not consume the queue,
  and says why at boot, rather than OOM the same packages again. Every other
  config passes through.
  """
  @spec with_checked_queue(keyword()) :: keyword()
  def with_checked_queue(oban_config) do
    queues = Keyword.get(oban_config, :queues)

    case Portal.Builder.check_toolchain_big_memory(queues) do
      :ok ->
        oban_config

      {:error, {_reason, big, toolchain}} ->
        Logger.error(
          "not running the toolchain_big queue: its memory limit " <>
            "(NCC_TOOLCHAIN_BIG_MEMORY, else NCC_BUILD_MEMORY) is #{inspect(big)}, " <>
            "not above the toolchain limit #{inspect(toolchain)}; set " <>
            "NCC_TOOLCHAIN_BIG_MEMORY higher, or take toolchain_big out of OBAN_QUEUES"
        )

        Keyword.put(oban_config, :queues, Keyword.delete(queues, @big))
    end
  end

  @doc "The queue for big packages."
  @spec big_queue() :: :toolchain_big
  def big_queue, do: @big

  @doc "How many days of the memory record count."
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc "The peak, in percent of the limit, from which a run counts as near the limit."
  @spec near_limit() :: pos_integer()
  def near_limit, do: @near_limit

  @doc """
  The names among `packages` whose memory record makes them big: a toolchain
  run in the window that was OOM-killed or peaked at `near_limit/0` percent
  of its limit or more. One query, on the `(package, kind, finished_at)` index.
  """
  @spec big_packages([String.t()], keyword()) :: MapSet.t(String.t())
  def big_packages(packages, opts \\ [])

  def big_packages([], _opts), do: MapSet.new()

  def big_packages(packages, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    since = DateTime.add(now, -@window_days * 86_400, :second)

    from(r in "catalog_run_memory",
      where: r.package in ^Enum.uniq(packages) and r.kind == "toolchain",
      where: r.finished_at >= ^since,
      where:
        r.oom_killed or
          (not is_nil(r.peak_used_bytes) and not is_nil(r.memory_limit_bytes) and
             r.memory_limit_bytes > 0 and
             r.peak_used_bytes * 100 >= r.memory_limit_bytes * @near_limit),
      distinct: true,
      select: r.package
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  A function from a package name to its queue, for enqueueing builds of
  `packages`: one record query and one liveness check for all of them.
  """
  @spec router([String.t()], keyword()) :: (String.t() -> :toolchain | :toolchain_big)
  def router(packages, opts \\ []) do
    big = if live?(opts), do: big_packages(packages, opts), else: MapSet.new()
    &queue_of(big, &1)
  end

  defp queue_of(big, package),
    do: if(MapSet.member?(big, package), do: @big, else: :toolchain)

  @doc """
  Whether some node runs `:toolchain_big`: a producer check for it with a
  limit above zero, paused or not. `:checks` (a zero-arity function returning
  `Oban.Met.checks/0`'s list) replaces the lookup, and so does `config
  :portal, #{inspect(__MODULE__)}, checks:`. Never raises: a lookup that
  fails is no producer.
  """
  @spec live?(keyword()) :: boolean()
  def live?(opts \\ []) do
    checks = Keyword.get_lazy(opts, :checks, &checks_fun/0)

    Enum.any?(checks.(), fn check ->
      check["queue"] == Atom.to_string(@big) and limit(check) > 0
    end)
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp checks_fun do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:checks, &Oban.Met.checks/0)
  end

  defp limit(check) do
    case check["local_limit"] || check["limit"] do
      limit when is_integer(limit) -> limit
      _ -> 0
    end
  end

  @doc """
  Moves the `ToolchainBuild` jobs that have been ready to run on
  `:toolchain_big` for more than half an hour back to `:toolchain`, while no
  node runs `:toolchain_big` (`live?/1`). Returns how many it moved. A job
  that is moved and OOMs again goes back to `:toolchain_big` only once a
  node runs it. `:now` and `:checks` are for tests.
  """
  @spec rescue_stranded(keyword()) :: non_neg_integer()
  def rescue_stranded(opts \\ []) do
    if live?(opts) do
      0
    else
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      before = DateTime.add(now, -@stranded_after_seconds, :second)

      {count, _} =
        Repo.update_all(
          from(j in Oban.Job,
            where: j.worker in ["Portal.Workers.ToolchainBuild", "Portal.Workers.PinnedBuild"],
            where: j.queue == ^Atom.to_string(@big),
            where: j.state in @queued_states,
            where: j.scheduled_at < ^before
          ),
          set: [queue: "toolchain"]
        )

      if count > 0 do
        Logger.warning(
          "No node runs the toolchain_big queue: moved #{count} toolchain builds back to toolchain"
        )
      end

      count
    end
  end

  @doc """
  Moves the executing job `id` from `:toolchain` to `:toolchain_big`, so its
  next attempt runs there: Oban's retry keeps the row's queue. Only while
  `live?/1`; returns whether it moved the row.
  """
  @spec move_to_big(integer() | nil, keyword()) :: boolean()
  def move_to_big(id, opts \\ [])

  def move_to_big(id, opts) when is_integer(id) do
    if live?(opts) do
      {count, _} =
        Repo.update_all(
          from(j in Oban.Job,
            where: j.id == ^id and j.queue == "toolchain" and j.state == "executing"
          ),
          set: [queue: Atom.to_string(@big)]
        )

      count == 1
    else
      false
    end
  end

  def move_to_big(_id, _opts), do: false
end
