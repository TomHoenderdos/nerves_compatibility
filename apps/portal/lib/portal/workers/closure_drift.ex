defmodule Portal.Workers.ClosureDrift do
  @moduledoc """
  Oban worker (queue `:intake`, a daily cron and a manual run) that
  rebuilds the toolchain builds a new dependency release left behind, and
  the firmware targets a dependency or system release left behind.

  ## The decay it stops

  A toolchain build records the dependency lock it was made with, and a
  client takes it only when its own lock agrees. When a dependency in the
  closure publishes a release the package's requirements allow, a fresh
  `mix deps.get` locks the new release, and the build stops hitting for every
  new project, though nothing about the package changed: `fledex_scheduler
  0.4.0`, built against `certifi 2.18.0`, misses with "lock has 2.19.0" from
  the day 2.19.0 is out. `Portal.Workers.UpdateCheck` only notices releases
  of the packages themselves, and `Portal.Workers.ToolchainSweep` only builds
  identities it has no row for, so nothing rebuilt such a build and hit rates
  decayed with every dependency release.

  ## What a run does

  Like `UpdateCheck`, it is stateless: each run reads the whole Hex registry
  (`Portal.HexRegistry.snapshot/1`, every release of every package), so a
  dependency release is visible until the builds it left behind are rebuilt,
  however long ago it came out. It takes the passing builds of each
  package's newest stable release on the configured toolchains at the
  current `builder_version` (`Portal.Catalog.ClosureDrift.candidates/2`),
  most downloaded package first, and asks `Portal.Catalog.ClosureDrift.drift/3`
  whether a fresh resolve would lock a dependency newer. That check is
  conservative: a newer release counts only when every requirement on it in
  the closure, at the locked versions, allows it.

  Each drifted build is queued as an ordinary `Portal.Workers.ToolchainBuild`
  with the sweep's own args, so the worker's unique keys dedupe it against a
  build the sweep already queued, at priority 3 (with the sweep's refreshes,
  behind every new build), on the queue `Portal.Toolchains.MemoryRouting`
  picks. Its args also say why: `reason: "closure_drift"` and `drift`, the
  dependencies that moved (`%{"dep", "from", "to"}`). At most `max_per_run/0`
  are queued per run, and the cron runs once a day, which is the daily cap;
  at most `scan_limit` builds are judged per run.

  A run asks Hex about each closure member at most once, a failed read
  included, and never retries one: a build whose closure could not be read
  is judged again tomorrow. So its Hex reads are bounded by the packages the
  judged closures name (about 400 on production, about 1,800 with the
  firmware phase), not by the builds, and a slow `repo.hex.pm` costs at most
  the read timeout per package, and the whole run at most `budget_ms/0`,
  after which it reads, judges and queues nothing more. It runs on
  `:intake`, the web host's HTTP queue, as `Portal.Workers.CoverageRefresh`
  does, rather than on the single `:maintenance` slot that signs the
  precompiled batch and reaps builder leases.

  ## The old build keeps serving

  The rebuild replaces its row only when it lands, so the old build serves
  until then. And it keeps serving after: before queueing, the run keeps the
  build in the row's `earlier_builds` (`ToolchainBuild.EarlierBuilds`), under
  the identity's ingest lock, so a project still locked at the older
  dependency keeps its hit. Keeping it here rather than only at the ingest
  makes it hold whichever node ingests the rebuild, including a builder not
  yet deployed with this release; the ingest keeps it too, for rebuilds this
  worker did not queue.

  ## Firmware targets

  A firmware run's targets drift the same way, and also fall behind when
  their system releases a version their build is not used on. After the
  toolchain builds, a run asks `Portal.Catalog.FirmwareDrift` about each
  package's latest run of its newest release, with the same registry and
  Hex reads, most downloaded package first, `firmware_scan_limit` runs a
  page, reading on past pages whose runs are all current until the cap is
  reached or the runs run out, and queues one forced targets
  build (`Portal.Workers.Build.scope_args/3`) of only the targets it names,
  through `Portal.Builders.Routing`, at priority 8: below a new release of a
  tracked package, above bulk sweeps. Its args carry `reason` and `drift`
  as above, a system bump naming the system as its `dep`. A package with a
  build or lease already on the way is not queued again (`pending`), since
  such a build's unique window is a minute and it may wait for days. One
  that waited past the run of a newer release is dropped rather than built
  in full (`Portal.Workers.Build.superseded_drift?/1`).

  A firmware rebuild is a container run of minutes, so its cap is separate
  and smaller (`firmware_max_per_run/0`), and counts the drift builds still
  waiting and those queued earlier the same day, so a retry or a second run
  does not queue past it. Nothing has to be kept for the old
  lock: every run is its own row, the manifest lists one build per target,
  system release and lock across all of a package's runs, and the rebuild
  carries the targets it leaves out, so the replaced build keeps serving
  projects still locked to the old dependency.

  ## Enablement

  On by default. `NCC_CLOSURE_DRIFT=0` switches the schedule off at runtime
  and `NCC_CLOSURE_DRIFT_MAX` sets the per-run cap; `NCC_FIRMWARE_DRIFT=0`
  switches the firmware phase off and `NCC_FIRMWARE_DRIFT_MAX` sets its cap.
  A `"manual"` run ignores the schedule switch, not the firmware one, and a
  `"dry_run"` one queues and writes nothing.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Builders.Routing
  alias Portal.BulkRebuild
  alias Portal.Catalog.ClosureDrift
  alias Portal.Catalog.FirmwareDrift
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.ToolchainBuild, as: ToolchainRow
  alias Portal.Catalog.ToolchainBuild.EarlierBuilds
  alias Portal.Precompiled.SystemAbi
  alias Portal.Repo
  alias Portal.Toolchains
  alias Portal.Toolchains.MemoryRouting
  alias Portal.Workers.ToolchainBuild

  @priority 3
  # Firmware rebuilds sit below a new release of a tracked package
  # (`:update_check`, 7) and above bulk sweeps and seeding (9).
  @firmware_priority 8
  @reason "closure_drift"
  @build_workers ~w(Portal.Workers.Build Portal.Workers.RemoteBuild)
  @incomplete ~w(available scheduled executing retryable)
  @lease_in_flight ~w(queued leased uploading)
  @outcomes %{enqueued: 0, pending: 0, unknown: 0}
  # At most this many changes ride in a job's args, which Oban Web shows.
  @changes_shown 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    if args["manual"] == true or enabled?() do
      with {:ok, summary} <- run(dry_run: args["dry_run"] == true) do
        record_summary(job, summary)
        {:ok, summary}
      end
    else
      :ok
    end
  end

  # Parked on the job row, as `UpdateCheck` does: Oban keeps and prunes it.
  defp record_summary(%Oban.Job{id: id, meta: meta}, summary) do
    merged = Map.merge(meta || %{}, Map.new(summary, fn {k, v} -> {Atom.to_string(k), v} end))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [meta: merged])
    :ok
  end

  @doc """
  One run: judge the candidates and queue the drifted builds' rebuilds.
  Returns `{:ok, %{candidates, drifted, enqueued, pending, unknown}}`:
  builds judged, found drifted, newly queued, already queued (a unique
  conflict), and whose closure could not be read. While the firmware phase
  is on (`firmware_enabled?/0`) the summary also has `firmware`, the same
  counts for runs plus `targets`, the targets of the drifted runs. Option
  `:dry_run` judges without queueing or writing anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    deadline = System.monotonic_time(:millisecond) + budget_ms()

    with {:ok, registry} <- registry_source().snapshot(all_versions: true) do
      index = ClosureDrift.index(registry)
      images = Map.new(Toolchains.images(), &{&1.toolchain, &1.image})
      builder_version = Toolchains.builder_version()

      candidates =
        ClosureDrift.candidates(index,
          builder_version: builder_version,
          toolchains: Map.keys(images),
          variants: ToolchainRow.optional_deps_variants() ++ Toolchains.world_variants(),
          limit: scan_limit()
        )

      queue_for = MemoryRouting.router(candidates |> Enum.map(& &1.package) |> Enum.uniq())
      {memo, releases} = memoized_releases(deadline)

      context = %{
        images: images,
        builder_version: builder_version,
        queue_for: queue_for,
        releases: releases,
        deadline: deadline
      }

      summary =
        try do
          candidates
          |> judge_all(index, context, dry_run?)
          |> log_summary()
          |> put_firmware(index, releases, dry_run?, deadline)
        after
          Process.delete(memo)
        end

      {:ok, put_out_of_time(summary, deadline)}
    end
  end

  # In candidate order, until `max_per_run/0` are queued or the run's time
  # budget is spent.
  defp judge_all(candidates, index, context, dry_run?) do
    max = max_per_run()
    summary = %{candidates: length(candidates), drifted: 0, enqueued: 0, pending: 0, unknown: 0}

    Enum.reduce_while(candidates, summary, fn
      _candidate, %{enqueued: enqueued} = acc when enqueued >= max ->
        {:halt, acc}

      candidate, acc ->
        if out_of_time?(context.deadline),
          do: {:halt, acc},
          else: {:cont, judge(candidate, index, context, dry_run?, acc)}
    end)
  end

  # A run reads Hex once per closure member, up to 15 s a read and about two
  # thousand members a day across both phases, so a slow `repo.hex.pm` could
  # keep it going for hours: past `Oban.Plugins.Lifeline`'s `rescue_after`
  # it would be rescued and run again beside itself. Past `budget_ms/0` it
  # judges, reads and queues nothing more; tomorrow's run picks up the rest.
  defp out_of_time?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp put_out_of_time(summary, deadline) do
    if out_of_time?(deadline) do
      Logger.warning("Closure drift: stopped at its time budget of #{budget_ms()} ms")
      Map.put(summary, :out_of_time, true)
    else
      summary
    end
  end

  defp judge(candidate, index, context, dry_run?, acc) do
    case ClosureDrift.drift(candidate, index, context.releases) do
      {:drift, changes} when dry_run? ->
        log_drift(candidate, changes)
        %{acc | drifted: acc.drifted + 1}

      {:drift, changes} ->
        log_drift(candidate, changes)
        outcome = rebuild(candidate, changes, context)
        Map.update!(%{acc | drifted: acc.drifted + 1}, outcome, &(&1 + 1))

      :current ->
        acc

      {:error, reason} ->
        Logger.info("Closure drift: #{describe(candidate)} not judged: #{inspect(reason)}")
        %{acc | unknown: acc.unknown + 1}
    end
  end

  defp log_drift(candidate, changes) do
    moved = Enum.map_join(changes, ", ", &"#{&1["dep"]} #{&1["from"]} -> #{&1["to"]}")
    Logger.info("Closure drift: #{describe(candidate)} drifted (#{moved})")
  end

  defp describe(%{targets: targets} = c),
    do: "#{c.package} #{c.version} (#{Enum.join(targets, ", ")})"

  defp describe(c),
    do: "#{c.package} #{c.version} (#{c.toolchain}, #{c.variant}, #{c.config_variant})"

  # Keep the build first, then queue its rebuild: the job may run on another
  # node at once, and its ingest must find the build already kept.
  defp rebuild(candidate, changes, context) do
    :ok = keep_build(candidate, context.builder_version)

    args = %{
      package: candidate.package,
      version: candidate.version,
      toolchain: candidate.toolchain,
      image: Map.fetch!(context.images, candidate.toolchain),
      builder_version: context.builder_version,
      variant: candidate.variant,
      config_variant: candidate.config_variant,
      reason: @reason,
      drift: Enum.take(changes, @changes_shown)
    }

    opts = [priority: @priority, queue: context.queue_for.(candidate.package)]

    case args |> ToolchainBuild.new(opts) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        :pending

      {:ok, _job} ->
        :enqueued

      {:error, reason} ->
        Logger.error("Closure drift could not queue #{describe(candidate)}: #{inspect(reason)}")
        :unknown
    end
  end

  # Under the identity's ingest lock (`Ingestion.lock_toolchain_identity/1`,
  # which every release takes), so an ingest of the same identity cannot
  # interleave with this read and write.
  defp keep_build(candidate, builder_version) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok =
          Ingestion.lock_toolchain_identity(%{
            package: candidate.package,
            version: candidate.version,
            toolchain: candidate.toolchain,
            builder_version: builder_version,
            variant: candidate.variant,
            config_variant: candidate.config_variant
          })

        row = Ash.get!(ToolchainRow, candidate.id, domain: Portal.Catalog)
        earlier = EarlierBuilds.keep(row)

        if earlier != List.wrap(row.earlier_builds) do
          row
          |> Ash.Changeset.for_update(:record_earlier_builds, %{earlier_builds: earlier})
          |> Ash.update!(domain: Portal.Catalog)
        end

        :ok
      end)

    :ok
  end

  defp log_summary(summary) do
    Logger.info(
      "Closure drift: #{summary.candidates} builds behind a release, #{summary.drifted} drifted, " <>
        "#{summary.enqueued} queued, #{summary.pending} already queued, #{summary.unknown} unread"
    )

    summary
  end

  # The firmware phase (moduledoc), with the run's registry and Hex reads.
  defp put_firmware(summary, index, releases, dry_run?, deadline) do
    if firmware_enabled?() do
      firmware = firmware(index, releases, dry_run?, deadline)

      Logger.info(
        "Firmware drift: #{firmware.candidates} runs behind a release, #{firmware.drifted} " <>
          "drifted (#{firmware.targets} targets), #{firmware.enqueued} queued, " <>
          "#{firmware.pending} already on the way, #{firmware.unknown} unread, " <>
          "#{firmware.earlier} queued earlier against the cap"
      )

      Map.put(summary, :firmware, firmware)
    else
      summary
    end
  end

  # A dry run judges as far as the cap would reach on an empty day.
  defp firmware(index, releases, dry_run?, deadline) do
    earlier = if dry_run?, do: 0, else: firmware_spent()

    context = %{
      judge: {index, releases, SystemAbi.table()},
      dry_run?: dry_run?,
      max: max(firmware_max_per_run() - earlier, 0),
      page: firmware_scan_limit(),
      deadline: deadline
    }

    summary = Map.merge(%{candidates: 0, drifted: 0, targets: 0, earlier: earlier}, @outcomes)
    scan_firmware(nil, summary, context)
  end

  # The firmware rebuilds the cap has already spent: drift builds still
  # waiting or running, queued on any day, and those queued since midnight
  # UTC whatever became of them. So a retry of this job, a manual run or a
  # second run the same day queues no more than the cap in all, and drift
  # builds that have waited since an earlier day hold back new ones rather
  # than pile up. Oban keeps a finished job 12 hours (`Oban.Plugins.Pruner`),
  # so a run late in the day finds fewer of the morning's; and a remote
  # build's job finishes once its lease is written, so a lease still waiting
  # for a builder from an earlier day is not counted.
  defp firmware_spent do
    today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    Repo.one(
      from(j in Oban.Job,
        where:
          j.worker in ^@build_workers and fragment("?->>'reason'", j.args) == ^@reason and
            fragment("?->>'scope'", j.args) == "targets" and
            (j.state in ^@incomplete or j.inserted_at >= ^today),
        select: count()
      )
    )
  end

  # Page by page, most downloaded first, until the cap is reached, the runs
  # run out or the time budget is spent: a page can hold only runs that are
  # current (`FirmwareDrift.candidates/2`), and the drifted ones below it
  # must still be reached.
  defp scan_firmware(cursor, acc, context) do
    if out_of_time?(context.deadline),
      do: acc,
      else: scan_firmware_page(cursor, acc, context)
  end

  defp scan_firmware_page(cursor, acc, context) do
    {index, _releases, _systems} = context.judge

    page =
      FirmwareDrift.candidates(index,
        systems: BulkRebuild.targets(),
        limit: context.page,
        after: cursor
      )

    acc =
      Enum.reduce_while(
        page,
        %{acc | candidates: acc.candidates + length(page)},
        &judge_firmware_next(&1, &2, context)
      )

    if page == [] or length(page) < context.page or acc.enqueued >= context.max,
      do: acc,
      else: scan_firmware(page |> List.last() |> FirmwareDrift.cursor(), acc, context)
  end

  defp judge_firmware_next(run, acc, context) do
    if acc.enqueued >= context.max or out_of_time?(context.deadline),
      do: {:halt, acc},
      else: {:cont, judge_firmware(run, context.judge, context.dry_run?, acc)}
  end

  defp judge_firmware(run, {index, releases, systems}, dry_run?, acc) do
    case FirmwareDrift.judge(run, index, releases, systems) do
      {:rebuild, targets, changes} ->
        log_drift(%{package: run.package, version: run.version, targets: targets}, changes)
        acc = %{acc | drifted: acc.drifted + 1, targets: acc.targets + length(targets)}

        if dry_run?,
          do: acc,
          else: Map.update!(acc, rebuild_firmware(run, targets, changes), &(&1 + 1))

      :current ->
        acc

      {:error, reason} ->
        Logger.info(
          "Firmware drift: #{run.package} #{run.version} not judged: #{inspect(reason)}"
        )

        %{acc | unknown: acc.unknown + 1}
    end
  end

  # A forced targets build of the latest tested version, which
  # `Portal.Workers.Build.scope_args/3` honours, through the routing every
  # build takes. Its unique window is a minute, so a build of the package
  # already waiting (any version, local or leased) is what dedupes it: one
  # queued yesterday at this priority may still be waiting.
  defp rebuild_firmware(run, targets, changes) do
    if firmware_pending?(run.package) do
      :pending
    else
      args = %{
        package: run.package,
        version: run.version,
        force: true,
        scope: "targets",
        systems: targets,
        reason: @reason,
        drift: Enum.take(changes, @changes_shown)
      }

      case args |> Routing.build_job(priority: @firmware_priority) |> Oban.insert() do
        {:ok, %Oban.Job{conflict?: true}} ->
          :pending

        {:ok, _job} ->
          :enqueued

        {:error, reason} ->
          Logger.error(
            "Firmware drift could not queue #{run.package} #{run.version}: #{inspect(reason)}"
          )

          :unknown
      end
    end
  end

  defp firmware_pending?(package) do
    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker in ^@build_workers and j.state in ^@incomplete and
            fragment("?->>'package'", j.args) == ^package
      )
    ) or
      Repo.exists?(
        from(l in "builder_leases",
          where: l.package == ^package and l.state in ^@lease_in_flight
        )
      )
  end

  # `Portal.HexDeps.releases/2` once per package for the run, its answer
  # (an error too) kept in this process until the run ends (moduledoc).
  # Past the deadline it reads nothing more (`out_of_time?/1`).
  defp memoized_releases(deadline) do
    memo = {__MODULE__, :releases, make_ref()}
    Process.put(memo, %{})

    {memo, &memoized_release(memo, &1, deadline)}
  end

  defp memoized_release(memo, name, deadline) do
    case Map.fetch(Process.get(memo), name) do
      {:ok, answer} ->
        answer

      :error ->
        if out_of_time?(deadline),
          do: {:error, :out_of_time},
          else: read_releases(memo, name)
    end
  end

  defp read_releases(memo, name) do
    answer = hex_deps().releases(name, receive_timeout: 15_000, retry: false)
    Process.put(memo, Map.put(Process.get(memo), name, answer))
    answer
  end

  @doc "Whether the scheduled run is switched on (`NCC_CLOSURE_DRIFT`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) == true

  @doc "At most this many rebuilds per run (`NCC_CLOSURE_DRIFT_MAX`), one run a day."
  @spec max_per_run() :: non_neg_integer()
  def max_per_run, do: Keyword.get(config(), :max_per_run, 500)

  defp scan_limit, do: Keyword.get(config(), :scan_limit, 5_000)

  @doc """
  How long a run may judge, read Hex and queue, in milliseconds; past it a
  run stops and the next one picks up the rest. Well under
  `Oban.Plugins.Lifeline`'s `rescue_after`, so the run is never rescued and
  run a second time while it is still working.
  """
  @spec budget_ms() :: non_neg_integer()
  def budget_ms, do: Keyword.get(config(), :budget_ms, :timer.minutes(60))

  @doc "Whether a run also rebuilds drifted firmware targets (`NCC_FIRMWARE_DRIFT`)."
  @spec firmware_enabled?() :: boolean()
  def firmware_enabled?, do: Keyword.get(config(), :firmware, true) == true

  @doc """
  At most this many firmware drift rebuilds waiting or queued the same UTC
  day, across runs (`NCC_FIRMWARE_DRIFT_MAX`).
  """
  @spec firmware_max_per_run() :: non_neg_integer()
  def firmware_max_per_run, do: Keyword.get(config(), :firmware_max_per_run, 100)

  defp firmware_scan_limit, do: Keyword.get(config(), :firmware_scan_limit, 1_000)

  defp config, do: Application.get_env(:portal, __MODULE__, [])

  defp registry_source,
    do: Application.get_env(:portal, :hex_registry_source, Portal.HexRegistry)

  defp hex_deps, do: Application.get_env(:portal, :hex_deps, Portal.HexDeps)
end
