defmodule Portal.Workers.ToolchainSweep do
  @moduledoc """
  Oban worker (queue `:maintenance`, a cron every 15 minutes and the admin
  Maintenance button) that enqueues a `Portal.Workers.ToolchainBuild` for
  every package version and optional-deps variant still missing a build on a
  configured toolchain (`Portal.Catalog.toolchain_backlog/3`), at most
  `Portal.Toolchains.max_per_run/0` in total.

  The backlog runs tens of thousands deep and the builders drain several times
  `max_per_run/0` a day, so the cron runs every 15 minutes. An unforced run
  first counts the `Portal.Workers.ToolchainBuild` jobs already `available`,
  `scheduled` or `retryable`. At `Portal.Toolchains.sweep_skip_when_queued/0`
  or more, it logs one line and returns without touching the backlog query or
  the Hex registry. This is what makes the frequent cron cheap: the expensive
  part of a run only happens when the queue actually needs topping up. The
  manual/admin trigger (`enqueue/0`, the Maintenance button) sets `force:
  true` in the job's args and always runs, queue or no queue.

  A `with` build is queued ahead of a `without` one (a lower Oban priority):
  it is the build a fresh project resolves, and the `without` build is only
  wanted because a `with` build exists.

  The cap is shared round-robin: each toolchain's backlog is taken in its own
  priority order (most downloaded first, see `Catalog.toolchain_backlog/3`)
  and the toolchains take turns, so one toolchain with a long backlog cannot
  starve the others inside a run. A toolchain with less backlog than its
  share leaves the rest to the others.

  The run is taken in four tiers, each round-robin over the toolchains: the
  named config variants (`config_variant` in `Catalog.toolchain_backlog/3`: a
  served default build's variants under the pinned
  `Compatibility.ConfigVariants` overlays it read), every `default` build
  that is not a refresh, the refreshes (`refresh`: a rebuild of a build
  already served, only to record its compile-time config reads), and the
  reopens (`reopen`: a skipped row, named or default, judged under an older
  judge revision and rebuilt only for that). They share the cap in this
  order:

    1. every named variant that is not a reopen, up to the whole cap;
    2. defaults that are not reopens, up to the cap less the refresh
       reserve and the named variants taken;
    3. refreshes, up to the reserve, a quarter of the cap;
    4. any slot still free, to the defaults left over, then the reopens,
       then the refreshes left over, so no slot goes unused.

  An older Hex release of a popular package (`Portal.Catalog.VersionBackfill`,
  `backfill` in `Catalog.toolchain_backlog/3`) is a new default build: it
  sits in tier 2 and ranks with the rest by package downloads, ahead of every
  reopen. It takes at most `Portal.Toolchains.backfill_share/0` (a third by
  default) of tier 2's slots, so the thousands of old releases of the top
  packages never hold back a new release of a lower-ranked one; a share the
  backfill does not fill goes to the other defaults, and slots the other
  defaults leave free go to the backfill. The registry is read for it once
  per run, not per toolchain.

  Reopens come after every new build: a judge revision reopens the whole
  skipped backlog of a toolchain at once, and it must not hold back a new
  version of a package, however few downloads it has.

  Named variants go first because a long default backlog (a
  `builder_version` bump makes every version new again) would otherwise take
  the whole cap on every run and never leave them a slot; they are bounded
  (at most a few per served default build), so new defaults slip by at most
  that many. The reserve exists for the same reason: after a bump the new
  defaults alone exceed the cap for days, and without it no refresh would be
  queued until they ran out. A run with fewer refreshes than the reserve
  gives the rest back to the defaults.

  Oban priorities are independent of the tiers: defaults at 0 and 1, named
  variants at 2, refreshes and reopens at 3. The tiers decide what a capped run
  enqueues, the priority what the queue runs first, so no build waits in the
  queue for a refresh.

  Jobs are inserted one at a time rather than with `Oban.insert_all/1`, which
  does not check `unique`: a build the previous sweep enqueued and the
  single-slot `:toolchain` queue has not reached yet is still backlog, and has
  to conflict rather than be queued twice. A conflict still counts against the
  cap; the queue's limit of 1, not the count, bounds the load.

  This worker's own `unique` (24 h, `states: :incomplete`) only blocks a new
  cron insert while an earlier one is still `available`, `scheduled`,
  `executing` or `retryable` -- not while one has `completed`, which is every
  run that returned `:ok`, skipped or not. Each cron insert carries the
  same args (`%{}`) as the last, so this only ever matters if a run is still
  in flight at the next tick; it does not turn the cron back into a daily one.
  """

  use Oban.Worker,
    queue: :maintenance,
    unique: [period: 86_400, states: :incomplete]

  import Ecto.Query

  require Logger

  alias Portal.Catalog
  alias Portal.Catalog.VersionBackfill
  alias Portal.Repo
  alias Portal.Toolchains
  alias Portal.Workers.ToolchainBuild

  # Oban states in which a ToolchainBuild job is still backlog: not yet run,
  # or waiting to be retried. `executing` is left out deliberately -- a job
  # the single-slot `:toolchain` queue is actively running is about to leave
  # this count, not stay in it, and counting it would make the guard trigger
  # one job sooner than the threshold says.
  @queued_states ~w(available scheduled retryable)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if args["force"] == true or not queue_topped_up?() do
      sweep()
    else
      Logger.info(
        "Toolchain sweep skipped: at least #{Toolchains.sweep_skip_when_queued()} " <>
          "ToolchainBuild jobs are already queued"
      )

      :ok
    end
  end

  # Whether at least `threshold` ToolchainBuild jobs are already queued, without
  # counting past it: an existence check for the threshold-th row (`offset`
  # skips to it, `limit: 1` asks for no more), one indexed scan bounded by the
  # threshold rather than a full count of a backlog that can run into the
  # thousands.
  defp queue_topped_up? do
    threshold = Toolchains.sweep_skip_when_queued()

    from(j in Oban.Job,
      where: j.worker == "Portal.Workers.ToolchainBuild",
      where: j.state in @queued_states,
      offset: ^(threshold - 1),
      limit: 1
    )
    |> Repo.exists?()
  end

  defp sweep do
    cap = Toolchains.max_per_run()
    builder_version = Toolchains.builder_version()

    backfill = VersionBackfill.wanted()

    backlogs =
      Enum.map(Toolchains.images(), fn image ->
        image.toolchain
        |> Catalog.toolchain_backlog(builder_version, cap, backfill: backfill)
        |> Enum.map(&{build_args(&1, image, builder_version), tier(&1)})
      end)

    counts =
      backlogs
      |> pick(cap)
      |> Enum.frequencies_by(&enqueue/1)

    for %{toolchain: toolchain} <- Toolchains.images() do
      [named, refresh, default, backfill, reopen] =
        for tier <- [:named, :refresh, :default, :backfill, :reopen],
            do: Map.get(counts, {toolchain, :enqueued, tier}, 0)

      pending =
        for tier <- [:named, :refresh, :default, :backfill, :reopen], reduce: 0 do
          sum -> sum + Map.get(counts, {toolchain, :pending, tier}, 0)
        end

      Logger.info(
        "Toolchain sweep #{toolchain} (builder #{builder_version}): " <>
          "enqueued #{named + default + backfill + refresh + reopen} " <>
          "(#{named} config variants, #{backfill} old releases, #{refresh} refreshes, " <>
          "#{reopen} judge-revision reopens), already queued #{pending}"
      )
    end

    :ok
  end

  @doc """
  Queue a sweep now (the admin button). Carries `force: true`, so it always
  runs `perform/1`'s backlog query and Hex calls even when the cron's
  top-up guard would otherwise skip -- a different `args` from the cron's
  `%{}`, so it never conflicts with a pending cron run either.
  `{:error, :already_queued}` while a forced sweep of its own is pending.
  """
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, :already_queued | term()}
  def enqueue do
    case %{force: true} |> new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :already_queued}
      other -> other
    end
  end

  # The run's builds, in enqueue order: each tier round-robin over the
  # toolchains, the cap shared as the moduledoc lays out. Named variants take
  # what they need; then the defaults and the refreshes each get their share
  # (the refreshes a quarter of the cap), and whatever either leaves goes to
  # the other's leftovers, defaults first. Reopens only fill what is left
  # after the leftover defaults, ahead of the leftover refreshes.
  defp pick(backlogs, cap) do
    [named, defaults, refreshes, reopens] =
      Enum.map([:named, :default, :refresh, :reopen], &round_robin(only(backlogs, &1)))

    named = Enum.take(named, cap)
    reserve = div(cap, 4)

    {defaults, more_defaults} =
      split_defaults(defaults, max(cap - reserve - length(named), 0))

    {refreshes, more_refreshes} = Enum.split(refreshes, reserve)

    Enum.take(
      named ++ defaults ++ refreshes ++ more_defaults ++ reopens ++ more_refreshes,
      cap
    )
  end

  # Tier 2: `slots` of the defaults, backfill included, in backlog order, and
  # the rest, other defaults ahead of backfill. Backfill takes at most its
  # share of the slots unless the other defaults leave some free; a share it
  # does not fill goes to them.
  defp split_defaults(defaults, slots) do
    {backfill, others} = Enum.split_with(defaults, &(elem(&1, 1) == :backfill))
    share = trunc(slots * Toolchains.backfill_share())
    others_taken = min(length(others), slots - min(length(backfill), share))
    backfill_taken = min(length(backfill), slots - others_taken)

    taken =
      MapSet.new(Enum.take(others, others_taken) ++ Enum.take(backfill, backfill_taken))

    {picked, rest} = Enum.split_with(defaults, &MapSet.member?(taken, &1))
    {more_backfill, more_others} = Enum.split_with(rest, &(elem(&1, 1) == :backfill))
    {picked, more_others ++ more_backfill}
  end

  # Each toolchain's backlog, keeping only the entries of `tier` (`:default`
  # includes `:backfill`), in their order.
  defp only(backlogs, :default) do
    Enum.map(backlogs, fn backlog ->
      Enum.filter(backlog, &(elem(&1, 1) in [:default, :backfill]))
    end)
  end

  defp only(backlogs, tier) do
    Enum.map(backlogs, fn backlog -> Enum.filter(backlog, &(elem(&1, 1) == tier)) end)
  end

  defp tier(%{refresh: true}), do: :refresh
  defp tier(%{reopen: true}), do: :reopen
  defp tier(%{config_variant: "default", backfill: true}), do: :backfill
  defp tier(%{config_variant: "default"}), do: :default
  defp tier(%{config_variant: _named}), do: :named

  defp build_args(
         %{package: package, version: version, variant: variant, config_variant: config_variant},
         image,
         builder_version
       ) do
    %{
      package: package,
      version: version,
      toolchain: image.toolchain,
      image: image.image,
      builder_version: builder_version,
      variant: variant,
      config_variant: config_variant
    }
  end

  defp enqueue({args, tier}) do
    case args |> ToolchainBuild.new(priority: priority(args.variant, tier)) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        {args.toolchain, :pending, tier}

      {:ok, _job} ->
        {args.toolchain, :enqueued, tier}

      {:error, reason} ->
        Logger.error(
          "Toolchain sweep could not enqueue #{args.package} #{args.version} " <>
            "(#{args.variant}, #{args.config_variant}) on #{args.toolchain}: #{inspect(reason)}"
        )

        {args.toolchain, :failed, tier}
    end
  end

  defp priority(_variant, :refresh), do: 3
  defp priority(_variant, :reopen), do: 3
  defp priority(_variant, :named), do: 2
  defp priority(:with, :default), do: 0
  defp priority(:without, :default), do: 1
  defp priority(variant, :backfill), do: priority(variant, :default)

  # [[a1, a2, a3], [b1]] -> [a1, b1, a2, a3]
  defp round_robin(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ round_robin(Enum.map(lists, &tl/1))
    end
  end
end
