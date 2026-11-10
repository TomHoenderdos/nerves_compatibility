defmodule Portal.Reports.Requeue do
  @moduledoc """
  Turns a report's "not built" misses (`codes/0`) into builds, when the portal
  would build them anyway.

  A report is an anonymous trigger and a build runs third-party code, so a
  line is queued only for a package the catalog already has a run of: the
  update check builds every new release of those, and only a package's owners
  can publish one, so a report can only make something happen sooner, never
  build a package an attacker published. The builds run in the usual sandbox
  (gVisor, the egress filter, a read-only root, no capabilities) and must
  never be enabled on a builder without it.

  Per line, in order; the first rule that applies is written to the line's
  `requeue`:

    1. The tuple: `(package, version, system, system_version)` for a report
       with a Nerves system, `(package, version, toolchain)` for a host report
       (`Portal.Toolchains.from_versions/2` of its Elixir and OTP), and
       `skipped:unbuildable` for a device report without a system.
    2. `skipped:unknown_package`: no run of the package at all.
    3. `skipped:not_on_hex`: Hex lists no such release (`Portal.HexDeps`,
       one cached lookup per known package of the report).
    4. `skipped:unbuildable`: no run of the last 30 days recorded that system
       version, or no configured image builds that toolchain.
    5. `skipped:judged`: a pass, fail or skipped result already stands for
       the tuple. An error or unknown one (a timeout, retries spent) does not.
    6. `skipped:queued`: a build of the package version is already waiting.
    7. `skipped:cap`: the day's global, package or reporter budget is spent
       (`Portal.Reports.Quotas`, on the UTC day; a report whose reporter key
       retention cleared counts against one shared `reporter:none` budget).
       The caps are reserved and the job inserted in one transaction, so a
       line that queues nothing spends nothing: a unique conflict with a job
       Oban already has is `skipped:queued`, and any other failure to insert
       is `skipped:error` (logged).
    8. `queued`: a system build through `Portal.Builders.Routing.build_job/2`
       (one forced target when the version already has a run, a full build
       otherwise), or a toolchain build of the `with`/`default` variant;
       either way `meta.report_id` names the report.

  `sweep/1` decides again, once a day, the lines a cap refused and the ones
  nothing decided.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Builders.Routing
  alias Portal.Reports.Quotas
  alias Portal.Repo
  alias Portal.Toolchains
  alias Portal.Workers.ToolchainBuild

  @codes ["not_built_version", "not_built_target"]
  @incomplete ~w(available scheduled executing retryable)
  @judged ~w(pass fail skipped)
  @buildable_days 30
  # The lowest Oban priority, for system and toolchain builds alike: a
  # report makes a build happen sooner than the sweeps would, never ahead of
  # them (`catalog_seed` and `backfill` builds also run at 9).
  @priority 9
  @sweep_days 7
  # An undecided line is the sweep's only once its report's own job had time.
  @undecided_after 3_600

  # $1 the oldest report retried, $2 the newest with undecided lines, $3 the
  # codes, $4 the job states that still count as waiting. A cleared reporter
  # key counts as one reporter (the empty string no key can equal).
  @sweep_sql """
  WITH candidates AS (
    SELECT l.id, l.package, l.version, l.report_id, l.inserted_at,
           coalesce(r.reporter_key, '') AS reporter, r.received_at
    FROM precompiled_report_lines l
    JOIN precompiled_reports r ON r.id = l.report_id
    WHERE r.received_at >= $1 AND l.status = 'miss' AND l.reason_code = ANY($3)
      AND (l.requeue = 'skipped:cap'
           OR (l.requeue IS NULL AND r.received_at < $2
               AND NOT EXISTS (
                 SELECT 1 FROM oban_jobs j
                 WHERE j.worker = 'Portal.Workers.ReportRequeue'
                   AND j.state::text = ANY($4)
                   AND j.args->>'report_id' = r.id::text)))
  ), ranked AS (
    SELECT package, version, count(DISTINCT reporter) AS reporters,
           min(received_at) AS first_seen
    FROM candidates
    GROUP BY package, version
  )
  SELECT c.id, c.package, c.version, c.report_id
  FROM candidates c
  JOIN ranked k USING (package, version)
  ORDER BY k.reporters DESC, k.first_seen ASC, c.package, c.version,
           c.received_at ASC, c.inserted_at ASC, c.id
  """

  @doc "The reason codes a requeue acts on."
  @spec codes() :: [String.t()]
  def codes, do: @codes

  @doc "Decides every undecided not-built miss of a report. A retracted report is `:ok`."
  @spec run_report(Ecto.UUID.t(), keyword()) :: :ok | {:error, :hex_unavailable}
  def run_report(report_id, opts \\ []) do
    lines =
      Repo.all(
        from(l in "precompiled_report_lines",
          where:
            l.report_id == type(^report_id, Ecto.UUID) and is_nil(l.requeue) and
              l.status == "miss" and l.reason_code in ^@codes,
          order_by: [asc: l.inserted_at, asc: l.id],
          select: %{
            id: type(l.id, Ecto.UUID),
            package: l.package,
            version: l.version,
            report_id: type(l.report_id, Ecto.UUID)
          }
        )
      )

    decide_lines(lines, opts)
  end

  @doc """
  The daily retry, just after the caps reset. It decides again, through
  `decide_lines/2`, the not-built misses of reports received in the last
  #{@sweep_days} days that either a cap refused (`skipped:cap`) or nothing
  decided: undecided lines of a report received over an hour ago whose own
  requeue job is no longer waiting (it gave up, say on a database error).

  The order is contested first: the package version the most distinct
  reporters asked for (a report whose reporter key retention cleared counts
  as one reporter), then the one first seen earliest, so one reporter cannot
  take the day's budget. Also prunes the counters of days more than a week
  before `:today`.

  Options as `decide_lines/2`, plus `:now`, which stands in for the clock.
  """
  @spec sweep(keyword()) :: :ok | {:error, :hex_unavailable}
  def sweep(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    _ = Quotas.prune(Date.add(today, -@sweep_days))

    %{rows: rows} =
      Repo.query!(@sweep_sql, [
        DateTime.add(now, -@sweep_days * 86_400, :second),
        DateTime.add(now, -@undecided_after, :second),
        @codes,
        @incomplete
      ])

    rows
    |> Enum.map(fn [id, package, version, report_id] ->
      %{
        id: Ecto.UUID.load!(id),
        package: package,
        version: version,
        report_id: Ecto.UUID.load!(report_id)
      }
    end)
    |> decide_lines(opts)
  end

  @doc """
  Decides `lines` in the order given and writes each decision. Hex is asked
  first, for every known package at once; if it cannot answer, nothing is
  written and `{:error, :hex_unavailable}` asks the caller to retry.

  Options (also of `run_report/2`): `:today`, the UTC day whose caps are
  spent (default `Date.utc_today/0`); `:hex_deps`, the module asked for
  releases (default `config :portal, :hex_deps`); `:insert`, the function that
  inserts a job changeset (default `Oban.insert/1`).
  """
  @spec decide_lines([map()], keyword()) :: :ok | {:error, :hex_unavailable}
  def decide_lines([], _opts), do: :ok

  def decide_lines(lines, opts) do
    with {:ok, hex} <- hex_versions(lines, opts) do
      reports = reports(lines)

      Enum.each(lines, fn line ->
        decision = decide(Map.fetch!(reports, line.report_id), line, hex, opts)

        Repo.update_all(
          from(l in "precompiled_report_lines", where: l.id == type(^line.id, Ecto.UUID)),
          set: [requeue: decision]
        )
      end)
    end
  end

  defp reports(lines) do
    ids = lines |> Enum.map(& &1.report_id) |> Enum.uniq()

    from(r in "precompiled_reports",
      where: r.id in type(^ids, {:array, Ecto.UUID}),
      select:
        {type(r.id, Ecto.UUID),
         %{
           id: type(r.id, Ecto.UUID),
           elixir: r.elixir,
           otp: r.otp,
           target: r.target,
           system: r.system,
           system_version: r.system_version,
           reporter_key: r.reporter_key
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Known packages (a run of any version) and the release versions Hex lists
  # for each. A package missing from the map is unknown.
  defp hex_versions(lines, opts) do
    packages = lines |> Enum.map(& &1.package) |> Enum.uniq()

    hex =
      Keyword.get_lazy(opts, :hex_deps, fn ->
        Application.get_env(:portal, :hex_deps, Portal.HexDeps)
      end)

    known =
      Repo.all(
        from(p in "catalog_packages",
          join: r in "catalog_runs",
          on: r.package_id == p.id,
          where: p.name in ^packages,
          distinct: true,
          select: p.name
        )
      )

    Enum.reduce_while(known, {:ok, %{}}, fn name, {:ok, acc} ->
      case hex.releases(name, receive_timeout: 10_000) do
        {:ok, releases} -> {:cont, {:ok, Map.put(acc, name, MapSet.new(releases, & &1.version))}}
        {:error, :not_found} -> {:cont, {:ok, Map.put(acc, name, MapSet.new())}}
        {:error, _unavailable} -> {:halt, {:error, :hex_unavailable}}
      end
    end)
  end

  defp decide(report, line, hex, opts) do
    with {:ok, key} <- key(report, line),
         :ok <- known(hex, line.package),
         :ok <- on_hex(hex, line.package, line.version),
         :ok <- buildable(key),
         :ok <- not_judged(key),
         :ok <- not_queued(key),
         :ok <- reserve_and_queue(key, report, opts) do
      "queued"
    else
      {:skip, why} -> "skipped:" <> why
    end
  end

  defp key(%{system: system, system_version: sv}, line) when is_binary(system) and is_binary(sv),
    do: {:ok, {:system, line.package, line.version, system, sv}}

  defp key(%{target: "host"} = report, line) do
    case Toolchains.from_versions(report.elixir, Integer.to_string(report.otp)) do
      nil -> {:skip, "unbuildable"}
      toolchain -> {:ok, {:toolchain, line.package, line.version, toolchain}}
    end
  end

  defp key(_report, _line), do: {:skip, "unbuildable"}

  defp known(hex, package),
    do: if(Map.has_key?(hex, package), do: :ok, else: {:skip, "unknown_package"})

  defp on_hex(hex, package, version),
    do: if(MapSet.member?(hex[package], version), do: :ok, else: {:skip, "not_on_hex"})

  defp buildable({:system, _package, _version, system, sv}) do
    since = DateTime.add(DateTime.utc_now(), -@buildable_days * 86_400, :second)

    built? =
      Repo.exists?(
        from(sr in "catalog_system_results",
          join: r in "catalog_runs",
          on: r.id == sr.run_id,
          where:
            sr.system_pkg == ^system and sr.system_version == ^sv and
              r.inserted_at > type(^since, :utc_datetime_usec)
        )
      )

    if built?, do: :ok, else: {:skip, "unbuildable"}
  end

  defp buildable({:toolchain, _package, _version, toolchain}) do
    if Enum.any?(Toolchains.images(), &(&1.toolchain == toolchain)),
      do: :ok,
      else: {:skip, "unbuildable"}
  end

  defp not_judged({:system, package, version, system, sv}) do
    judged? =
      Repo.exists?(
        from(sr in "catalog_system_results",
          join: r in "catalog_runs",
          on: r.id == sr.run_id,
          join: p in "catalog_packages",
          on: p.id == r.package_id,
          where:
            p.name == ^package and r.version_tested == ^version and sr.system_pkg == ^system and
              sr.system_version == ^sv and is_nil(sr.carried_from_run_id) and
              is_nil(r.revoked_at) and sr.status in ^@judged
        )
      )

    if judged?, do: {:skip, "judged"}, else: :ok
  end

  defp not_judged({:toolchain, package, version, toolchain}) do
    judged? =
      Repo.exists?(
        from(t in "catalog_toolchain_builds",
          join: p in "catalog_packages",
          on: p.id == t.package_id,
          where:
            p.name == ^package and t.version == ^version and t.toolchain == ^toolchain and
              t.builder_version == ^Toolchains.builder_version() and is_nil(t.revoked_at) and
              t.status in ^@judged and not (t.status == "skipped" and t.transient_attempts > 0)
        )
      )

    if judged?, do: {:skip, "judged"}, else: :ok
  end

  defp not_queued({:system, package, version, _system, _sv}) do
    job? =
      Repo.exists?(
        from(j in "oban_jobs",
          where:
            j.worker in ["Portal.Workers.Build", "Portal.Workers.RemoteBuild"] and
              j.state in ^@incomplete and fragment("?->>'package'", j.args) == ^package and
              fragment("?->>'version'", j.args) == ^version
        )
      )

    lease? =
      Repo.exists?(
        from(l in "builder_leases",
          where:
            l.package == ^package and l.version == ^version and
              l.state in ["queued", "leased", "uploading"]
        )
      )

    if job? or lease?, do: {:skip, "queued"}, else: :ok
  end

  defp not_queued({:toolchain, package, version, toolchain}) do
    job? =
      Repo.exists?(
        from(j in "oban_jobs",
          where:
            j.worker == "Portal.Workers.ToolchainBuild" and j.state in ^@incomplete and
              fragment("?->>'package'", j.args) == ^package and
              fragment("?->>'version'", j.args) == ^version and
              fragment("?->>'toolchain'", j.args) == ^toolchain
        )
      )

    if job?, do: {:skip, "queued"}, else: :ok
  end

  # The caps and the job in one transaction. A refused cap rolls back the
  # keys already reserved; a job Oban did not insert (an error, or a unique
  # conflict with a job it already has) rolls back the caps, so a line that
  # queued nothing spent nothing. A conflict means the build is already
  # there: `skipped:queued`. Any other failure is logged and `skipped:error`.
  defp reserve_and_queue(key, report, opts) do
    day = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    insert = Keyword.get(opts, :insert, &Oban.insert/1)
    caps = Quotas.caps()
    package = elem(key, 1)

    keys = [
      {"global", caps.global},
      {"package:" <> package, caps.package},
      {"reporter:" <> reporter_bucket(report.reporter_key), caps.reporter}
    ]

    Repo.transaction(fn ->
      with :ok <- Quotas.reserve(keys, day),
           {:ok, %Oban.Job{conflict?: false}} <- insert.(job(key, report)) do
        :ok
      else
        {:error, :cap} -> Repo.rollback(:cap)
        {:ok, %Oban.Job{conflict?: true}} -> Repo.rollback(:conflict)
        {:error, reason} -> Repo.rollback({:insert, reason})
        other -> Repo.rollback({:insert, other})
      end
    end)
    |> case do
      {:ok, :ok} ->
        :ok

      {:error, :cap} ->
        {:skip, "cap"}

      {:error, :conflict} ->
        {:skip, "queued"}

      {:error, {:insert, reason}} ->
        Logger.warning(
          "Report requeue could not queue #{package} #{elem(key, 2)}: #{inspect(reason)}"
        )

        {:skip, "error"}
    end
  end

  # A report whose reporter key was cleared (retention) shares one bucket.
  defp reporter_bucket(key) when is_binary(key), do: key
  defp reporter_bucket(nil), do: "none"

  defp job({:system, package, version, system, _sv}, report) do
    args =
      if run_exists?(package, version),
        do: %{
          package: package,
          version: version,
          force: true,
          scope: "targets",
          systems: [system]
        },
        else: %{package: package, version: version}

    Routing.build_job(args, priority: @priority, meta: %{report_id: report.id})
  end

  defp job({:toolchain, package, version, toolchain}, report) do
    %{image: image} = Enum.find(Toolchains.images(), &(&1.toolchain == toolchain))

    ToolchainBuild.new(
      %{
        package: package,
        version: version,
        toolchain: toolchain,
        image: image,
        builder_version: Toolchains.builder_version(),
        variant: "with",
        config_variant: "default"
      },
      priority: @priority,
      meta: %{report_id: report.id}
    )
  end

  defp run_exists?(package, version) do
    Repo.exists?(
      from(r in "catalog_runs",
        join: p in "catalog_packages",
        on: p.id == r.package_id,
        where: p.name == ^package and r.version_tested == ^version
      )
    )
  end
end
