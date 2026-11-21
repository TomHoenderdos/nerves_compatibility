defmodule Portal.Workers.UpdateCheck do
  @moduledoc """
  Oban worker (queue `:intake`) that notices when a package we have already
  tested publishes a new release, and queues a rebuild for it.

  Without this, every result on the site is a snapshot of whatever version was
  current when the package was last built, and it silently rots: nothing in the
  system ever asks hex.pm whether a version has moved. `Package.latest_version`
  does not answer that question either -- despite the name it records the
  highest version *we tested*, written from the build result in
  `Portal.Catalog.Ingestion`, so it only moves when a build happens, and
  never back (`Portal.Catalog.LatestRun`).

  ## Stateless, and not a window

  Each run compares our whole catalogue against the whole hex.pm registry, which
  `Portal.HexRegistry` delivers in two CDN requests. There is no watermark to
  store and no lookback to tune: a package that drifted last month is just as
  visible as one that drifted an hour ago, so a missed tick, a restart, or a
  deploy costs nothing.

  That is worth spelling out because the obvious alternatives are both worse. A
  stored watermark needs a table, a migration, and a new failure mode where
  losing it either re-checks everything or silently skips a day. A fixed lookback
  window needs no state but *drops* anything older than the cutoff -- which is
  exactly the backlog that accumulated before this worker existed, and which it
  would then never repair.

  Re-offering the same package on every run is free because the work is
  idempotent three layers deep: this worker only acts on a version newer
  than the one on record, `Portal.Workers.Backfill` is unique per package per
  day, `Portal.ScanRequests.create_once/1` is idempotent against an already-open
  request, and `Portal.Workers.Build` is unique on package/version/image.

  ## What earns a rebuild

  Not every release is worth a build. A registry version newer than the one
  on record, by Hex's precedence (`Portal.Catalog.LatestRun.newer?/2`), is a
  candidate. An older one is not: `latest_version` never moves back, so when
  a release we built leaves the registry (reverted within Hex's window),
  rebuilding the registry's version would change nothing and repeat on every
  run. `significant?/2` decides which updates earn a rebuild. Every eligible update is offered to the queue; existing job and
  request uniqueness prevents duplicate builds.

  ## A toolchain build for the release that earns no full run

  A patch release of a passing *pure* package earns no full run, so
  `latest_version` stays behind it, and a toolchain build is only ever
  wanted for a version with a run or one `Portal.Catalog.VersionBackfill`
  reaches. For such a release the run records the registry's latest
  version in `hex_latest_version` instead, which
  `Portal.Catalog.toolchain_backlog/3` offers as a new build (#105). It only
  nominates: the toolchain build compiles and judges that version itself.
  A prerelease is never nominated, and a nomination is cleared once a full
  run reaches its version or the backlog has nothing left to build of it:
  a verdict (not an `error`, which the backlog retries after a day) of its
  `with` build on every configured toolchain, and of the `without` build
  each `with` build wants.

  A package with native code in its dependency closure (`native?/1`, read
  the same way `Portal.Catalog.toolchain_backlog/3`'s pure-BEAM clause is)
  has no such path: that query restricts the `hex_latest_version` candidate
  to pure packages, because a toolchain build only ever compiles on the
  host, never on a Nerves target. Nominating a native package's patch
  release would record a version nothing ever builds, so instead it takes
  the ordinary rebuild path below -- the same one a minor or major release
  takes -- and its precompiled files keep coming from the firmware `Build`
  they always needed.

  ## A dependency's release

  This worker rebuilds a package when the package itself releases. A
  release of one of its dependencies leaves its toolchain builds' locks
  behind instead, which `Portal.Workers.ClosureDrift` rebuilds from the same
  registry once a day. A release that many packages' builds lock behind is
  handed to `Portal.Workers.ReleaseFastPath` from this run instead, which
  rebuilds them as soon as its budget allows.

  ## Scope

  Only packages already in the catalogue. A registry package we have never
  tested is not stale, it is absent, and seeding new packages belongs to
  `Portal.UpstreamBackfill`. Restricting it this way also bounds the work: we
  track roughly a ninth of hex.pm.

  ## Why queue `:intake`

  The work here is two HTTP requests and a handful of inserts, not a compile.
  `:intake` runs on the web host, which keeps a registry-wide check off the
  machine doing the builds it is queueing -- the same reasoning
  `Portal.Workers.Backfill` documents.

  ## Enablement

  On by default. `NCC_UPDATE_CHECK=0` switches it off at runtime without a
  deploy, and the cron entry runs either way: while disabled the run returns
  immediately, before any request to hex.pm.
  """

  use Oban.Worker,
    queue: :intake,
    # A failed check waits for the next tick rather than hammering hex.pm:
    # nothing is lost, because the next run sees the same drift. Two attempts
    # cover a transient blip without turning an outage into a retry storm.
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Catalog.LatestRun
  alias Portal.Catalog.Package
  alias Portal.Workers.Backfill
  alias Portal.Workers.ReleaseFastPath

  @doc """
  Args:

    * `"manual"` - an admin asked for this run, so it ignores the `:enabled`
      gate. That gate exists to stop the *schedule* sending hex.pm traffic, not
      to stop a person who is looking at the page from checking on purpose.
    * `"dry_run"` - classify and report without queueing anything.

  The cron entry passes neither.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    manual? = args["manual"] == true
    dry_run? = args["dry_run"] == true

    if manual? or enabled?() do
      case run(dry_run: dry_run?) do
        {:ok, summary} ->
          record_summary(job, summary, dry_run?)
          {:ok, summary}

        other ->
          other
      end
    else
      :ok
    end
  end

  # The numbers a run produced, parked on the job row that produced them.
  #
  # Written here rather than to a table of our own because Oban already keeps
  # exactly the row this belongs to, already timestamps it, and already prunes
  # it. A run happens hourly, so "the last run" is never old enough for the
  # pruner to have taken it, and nothing downstream needs the history.
  #
  # String keys, because this round-trips through jsonb and merging atom keys
  # into what comes back would silently give the map two of everything.
  defp record_summary(%Oban.Job{id: id, meta: meta}, summary, dry_run?) do
    merged =
      Map.merge(meta || %{}, %{
        "seen" => summary.seen,
        "moved" => summary.moved,
        "enqueued" => summary.enqueued,
        "nominated" => summary.nominated,
        "fast_path" => summary.fast_path,
        "dry_run" => dry_run?
      })

    Portal.Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [meta: merged])

    :ok
  end

  @doc """
  Diff the catalogue against the hex.pm registry and queue rebuilds.

  Runs regardless of the `:enabled` flag -- that gate belongs to the scheduled
  path, not to a human at a console deciding to run one on purpose.

  Returns `{:ok, %{seen: n, moved: n, enqueued: n, nominated: n, fast_path: n}}`,
  where `seen` counts registry packages, `moved` counts tracked packages
  worth rebuilding, `enqueued` counts newly inserted jobs, `nominated`
  counts packages whose `hex_latest_version` this run set, and `fast_path`
  the releases it handed to `Portal.Workers.ReleaseFastPath`. Existing jobs do not
  prevent other eligible updates from being queued.

  Metadata lookup jobs are scheduled one second apart, oldest updates first.
  Build concurrency and firmware selection are handled by the builder.

  Options:

    * `:dry_run` - classify without inserting anything.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    case registry_source().snapshot(all_versions: true) do
      {:ok, registry} ->
        {moved, patch_only, hidden} = moved(registry)
        dry_run? = Keyword.get(opts, :dry_run, false)

        enqueued =
          if dry_run? do
            0
          else
            moved |> oldest_first() |> Enum.with_index() |> Enum.count(&enqueue/1)
          end

        nominated =
          if dry_run? do
            0
          else
            clear_stale()
            nominate(patch_only ++ hidden)
          end

        fast_path = if dry_run?, do: 0, else: ReleaseFastPath.offer(registry)

        Logger.info(
          "Update check: #{length(registry)} packages on hex, #{length(moved)} tracked and worth rebuilding, #{enqueued} queued, #{nominated} toolchain builds nominated, #{fast_path} releases on the fast path"
        )

        {:ok,
         %{
           seen: length(registry),
           moved: length(moved),
           enqueued: enqueued,
           nominated: nominated,
           fast_path: fast_path
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # DateTime structs do not sort chronologically under Erlang term ordering.
  # Missing timestamps sort last so known older updates are processed first.
  defp oldest_first(moved) do
    Enum.sort_by(moved, fn entry ->
      case entry.updated_at do
        nil -> {1, 0}
        at -> {0, DateTime.to_unix(at)}
      end
    end)
  end

  defp moved(registry) do
    by_name = Map.new(registry, &{&1.name, &1})

    # The whole catalogue, not a filtered subset. Passing ~22,000 registry names
    # to the database as an `IN` list would be absurd; reading our own 2,500 rows
    # and intersecting in memory is bounded by the size of the catalogue.
    packages =
      Package
      |> Ash.Query.select([:id, :name, :latest_version, :hex_latest_version, :native_components])
      |> Ash.read!(domain: Portal.Catalog)

    drifted =
      Enum.flat_map(packages, fn package ->
        with {:ok, entry} <- Map.fetch(by_name, package.name),
             true <- LatestRun.newer?(entry.latest_version, package.latest_version) do
          [{package, entry}]
        else
          _ -> []
        end
      end)

    # Run statuses are only needed to decide the patch-release exception below,
    # so they are read for the few hundred packages that actually drifted rather
    # than for the whole catalogue.
    statuses = latest_run_statuses(Enum.map(drifted, fn {package, _entry} -> package.id end))

    {rebuild, patch_only} =
      Enum.split_with(drifted, &rebuild?(elem(&1, 0), elem(&1, 1), statuses))

    {Enum.map(rebuild, &elem(&1, 1)), patch_only, hidden_stable(packages, by_name)}
  end

  # The newest stable release of each tracked pure package whose registry
  # lists a newer prerelease after it, as a nomination candidate: earmark
  # lists 1.5.0-pre1 last, so the drift above compares that prerelease with
  # the one on record and sees nothing, while 1.4.49, which a fresh
  # `mix deps.get` resolves, never earns a run. `nominate/1` skips one a
  # toolchain build of exists. A retired release still counts: Hex resolves
  # it (`mix hex.retire`). A native package is left out, as for a patch
  # release: nothing builds its nomination.
  defp hidden_stable(packages, by_name) do
    for package <- packages,
        not is_nil(package.latest_version),
        not native?(package),
        {:ok, entry} <- [Map.fetch(by_name, package.name)],
        stable = newest_stable(entry),
        stable not in [nil, entry.latest_version, package.latest_version],
        package.hex_latest_version != stable,
        do: {package, %{entry | latest_version: stable}}
  end

  defp newest_stable(entry) do
    stable =
      for version <- Map.get(entry, :versions) || [entry.latest_version],
          {:ok, %Version{pre: []} = parsed} <- [Version.parse(version || "")],
          do: parsed

    if stable != [], do: stable |> Enum.max(Version) |> to_string()
  end

  # The registry's latest version of each package whose release earns no
  # full run, as a toolchain build candidate (`hex_latest_version`), unless
  # the backlog has nothing left to build of it (`nomination_done/4`). Counts
  # the rows it changed. A prerelease is never nominated: prerelease churn
  # would queue builds, and some prereleases are not to be published.
  defp nominate(patch_only) do
    toolchains = toolchains()
    builder_version = Portal.Toolchains.builder_version()

    patch_only
    |> Enum.filter(fn {_package, entry} -> stable?(entry.latest_version) end)
    |> Enum.count(fn {package, entry} ->
      %{num_rows: count} =
        Portal.Repo.query!(
          """
          UPDATE catalog_packages p SET hex_latest_version = $2
          WHERE p.id = $1::uuid AND p.hex_latest_version IS DISTINCT FROM $2
            AND NOT #{nomination_done("p.id", "$2", "$3", "$4")}
          """,
          [Ecto.UUID.dump!(package.id), entry.latest_version, toolchains, builder_version]
        )

      count == 1
    end)
  end

  defp stable?(version) do
    match?({:ok, %Version{pre: []}}, Version.parse(version || ""))
  end

  # A nomination is done once a full run reached its version, or once the
  # backlog has nothing left to build of it: on every configured toolchain,
  # at the current builder version, a verdict of its default `with` build
  # (any status but `error`, which is no verdict and which the backlog
  # retries after a day; or a revoked row) and, when that `with` build wants
  # its `without` one (it added an optional dependency; the backlog's rule),
  # a verdict of that one too. Clearing it any sooner leaves a version with
  # no run of its own no way into the backlog.
  defp clear_stale do
    Portal.Repo.query!(
      """
      UPDATE catalog_packages p SET hex_latest_version = NULL
      WHERE p.hex_latest_version IS NOT NULL
        AND (p.hex_latest_version = p.latest_version
             OR #{nomination_done("p.id", "p.hex_latest_version", "$1", "$2")})
      """,
      [toolchains(), Portal.Toolchains.builder_version()]
    )

    :ok
  end

  defp toolchains, do: Enum.map(Portal.Toolchains.images(), & &1.toolchain)

  defp nomination_done(package, version, toolchains, builder_version) do
    row = fn alias, variant ->
      """
      #{alias}.package_id = #{package} AND #{alias}.version = #{version}
        AND #{alias}.toolchain = tc.toolchain AND #{alias}.builder_version = #{builder_version}
        AND #{alias}.variant = '#{variant}' AND #{alias}.config_variant = 'default'
      """
    end

    """
    NOT EXISTS (
      SELECT 1 FROM unnest(#{toolchains}::text[]) AS tc(toolchain)
      WHERE NOT EXISTS (
              SELECT 1 FROM catalog_toolchain_builds w
              WHERE #{row.("w", "with")}
                AND (w.status <> 'error' OR w.revoked_at IS NOT NULL))
         OR EXISTS (
              SELECT 1 FROM catalog_toolchain_builds w
              WHERE #{row.("w", "with")}
                AND (w.status = 'pass' OR (w.status = 'skipped' AND w.portability_rule = 2))
                AND w.revoked_at IS NULL
                AND jsonb_typeof(w.optional_deps -> 'added') = 'array'
                AND jsonb_array_length(w.optional_deps -> 'added') > 0
                AND NOT EXISTS (
                  SELECT 1 FROM catalog_toolchain_builds o
                  WHERE #{row.("o", "without")}
                    AND (o.status <> 'error' OR o.revoked_at IS NOT NULL))))
    """
  end

  # A tracked package with no version on record has never produced a build
  # result. That is as stale as a version that moved, and the same rebuild is
  # the fix, so it belongs here rather than in a special case.
  defp rebuild?(%{latest_version: nil}, _entry, _statuses), do: true

  defp rebuild?(package, entry, statuses) do
    significant?(package.latest_version, entry.latest_version) or
      not passing?(package.id, statuses) or native?(package)
  end

  # A package with native code in its dependency closure, read the same way
  # `Portal.Catalog.toolchain_backlog/3`'s pure-BEAM clause is: a NIF
  # language, or any port language. A package with no `native_components` at
  # all reads as pure, same as there.
  #
  # The patch-release skip above only saves load for a pure package: a pure
  # package's skipped patch release is still nominated for a toolchain build
  # (`nominate/1`), but `toolchain_backlog/3` restricts that candidate to
  # pure packages, so a native package's nomination would be a verdict
  # nothing ever builds. Treating it as significant instead sends it down
  # the ordinary rebuild path, the same one a minor or major release takes.
  defp native?(%{native_components: nil}), do: false

  defp native?(%{native_components: components}) do
    not is_nil(components["nif_language"]) or port_language?(components)
  end

  defp port_language?(components) do
    case components["port_languages"] do
      languages when is_list(languages) -> Enum.any?(languages, &(not is_nil(&1)))
      _ -> false
    end
  end

  # Whether a version change is worth a rebuild on its own.
  #
  # Patch releases are 46% of the drift in this catalogue (178 of 388 measured
  # against the live registry) and are the releases least likely to change what
  # we measure -- compilation against a Nerves target, native components,
  # footprint. Skipping them nearly halves the rebuild volume for close to no
  # loss of signal, and a maintainer who wants a patch verified can still ask
  # for a scan by hand.
  #
  # The exception is in `rebuild?/3` above rather than here: a package whose
  # last run did not pass is rebuilt on *any* version change. A patch release on
  # a failing package is the most informative event we can observe -- it is
  # usually the maintainer fixing the thing we flagged -- and refusing to look
  # would leave a red badge that no release can ever clear. It costs little:
  # honouring it turns 170 skipped patch bumps into 178.
  defp significant?(from, to) do
    case {Version.parse(from), Version.parse(to)} do
      {{:ok, from}, {:ok, to}} ->
        cond do
          from.major != to.major -> true
          from.minor != to.minor -> true
          # A prerelease graduating to stable (0.19.0-beta.2 -> 0.19.0) is the
          # release that matters, even though every number before the `-` is
          # unchanged. Prerelease-to-prerelease churn is not.
          from.pre != [] and to.pre == [] -> true
          true -> false
        end

      # Something we cannot parse as semver. Rebuilding is the safe direction:
      # the cost is one build, where the alternative is silently never
      # rebuilding a package whose scheme we failed to read.
      _ ->
        true
    end
  end

  # The text column as stored: a run with no `overall_status` is not a passing
  # one.
  defp passing?(package_id, statuses), do: Map.get(statuses, package_id) == "pass"

  defp latest_run_statuses([]), do: %{}

  # The status of each package's latest run (`LatestRun`). Named columns on
  # purpose: `catalog_runs.log` holds the whole runner log of every run, and
  # an unselected read would load all of it to answer a question about one
  # atom.
  defp latest_run_statuses(package_ids) do
    from([r] in LatestRun.query(),
      where: r.package_id in type(^package_ids, {:array, Ecto.UUID}),
      select: {type(r.package_id, Ecto.UUID), r.overall_status}
    )
    |> Portal.Repo.all()
    |> Map.new()
  end

  # `source: update_check` is what separates these from a bulk catalogue seed.
  # Both land in `Backfill`, but a stale result on a package we already display
  # outranks a package we have never tested -- see `Portal.ScanRequests` for the
  # priority table and why the two must not share a number.
  # The version is for `Backfill`'s uniqueness only: a second release the
  # same day is a new job, while the same release offered again is not.
  defp enqueue({%{name: name, latest_version: version}, delay}) do
    case %{package: name, source: "update_check", version: version}
         |> Backfill.new(schedule_in: delay)
         |> Oban.insert() do
      # Already queued by an earlier run inside `Backfill`'s uniqueness period.
      # Continue offering the remaining updates even when one already exists.
      {:ok, %Oban.Job{conflict?: true}} ->
        false

      {:ok, _job} ->
        true

      {:error, reason} ->
        Logger.warning("Update check could not queue #{name}: #{inspect(reason)}")
        false
    end
  end

  @doc """
  Whether the *scheduled* check is switched on.

  Public because the admin page reports it: a panel that showed a last-run
  summary without saying whether more runs are coming would read the same
  whether the check was healthy or switched off an hour ago.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  defp config, do: Application.get_env(:portal, __MODULE__, [])

  defp registry_source,
    do: Application.get_env(:portal, :hex_registry_source, Portal.HexRegistry)
end
