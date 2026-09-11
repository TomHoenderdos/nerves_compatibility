defmodule Portal.Workers.LogRetention do
  @moduledoc """
  Oban worker (queue `:maintenance`) that keeps stored build logs inside a
  fixed budget.

  The log tables are the one part of the schema whose growth is driven by
  third-party build output rather than by the size of the package index: a bad
  week of failing builds across ~2500 packages can store tens of gigabytes
  without anyone having decided to. Every rule below bounds that.

  What this is *not* is a capacity emergency. Production Postgres is a
  self-hosted container on a 244 GB disk with 155 GB free (2026-09-11), shared
  with unrelated apps — `autosift_prod` alone is 23 GB against `portal_prod`'s
  1.0 GB. An earlier version of this docstring called it "a 1 GB managed
  Postgres already at 82%"; that was a misread of `catalog_system_results`'
  share *of the database* (843 MB of 1024 MB) as utilisation of a quota. No
  quota exists, here or upstream, so the budget below is a policy choice about
  unbounded third-party output rather than a ceiling someone else imposed.

  Three rules, cheapest first:

    * **Unreachable per-system logs.** `Portal.Catalog.system_log/2` resolves a
      log through the package's *latest* run, so the moment a package is built
      again every log from its previous run becomes unreachable — no page, no
      API, no query can reach it. Without this the rows would accumulate one
      failed run at a time, forever, at up to 800 KB each.

    * **The byte budget.** Reachability alone is not a bound. A package that
      fails on all fourteen Nerves systems stores fourteen logs, and there are
      ~2500 packages; the worst case is tens of gigabytes inside a one-gigabyte
      database. When the total exceeds the budget the oldest logs go first, so
      the recently-built packages — the ones somebody is actually looking at —
      keep theirs. `PortalWeb.LogLive` already redirects with a flash when a log
      is missing, which is exactly what a reader of an evicted log sees.

    * **`catalog_runs.log`.** The whole `runner.log` of every run, passing runs
      included: 105 MB in production, 97% of it from builds that succeeded, and
      not read by a single line of code in this repo. `Portal.Catalog.Ingestion`
      no longer stores one for a passing run; this clears what the old behaviour
      left behind, and stays as the backstop if the gate is ever lost.

  ## Why queue `:maintenance`

  Purely database work, so unlike `Portal.Workers.Sweep` — which must run on the
  build host because only that machine has the directories — this belongs on the
  web host, where `:maintenance` runs. Both hosts share one database, so it does
  not matter which of them does the deleting; it matters that it is not the
  machine with three builds on it.

  ## Reclaimed, not returned

  Postgres marks the deleted rows dead and reuses the space for later writes.
  Returning it to the operating system needs a `VACUUM FULL` (which takes an
  exclusive lock) or `pg_repack`. That is a deliberate one-off for an operator,
  not something a cron job should decide to do to a live database.
  """

  use Oban.Worker,
    # A failed pass waits for tomorrow's tick rather than retry-storming, and
    # never runs concurrently with itself: the budget query reads the whole
    # table and two of them would each delete based on a total the other is
    # already shrinking.
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Portal.Repo

  # A policy choice, not a ceiling — see the moduledoc; nothing caps this
  # database. What the number decides is how much build-log history the viewer
  # keeps, so it is a product question, not a capacity one.
  @default_budget_bytes 128 * 1024 * 1024

  @type tally :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  @type report :: %{unreachable: tally(), over_budget: tally(), run_logs: tally()}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run()
    :ok
  end

  @doc """
  Apply every retention rule and report what went.

  Returns one tally per rule rather than `:ok`. The summary is otherwise only
  visible in a log line, and the suite runs at `:warning` — a rule that
  silently stopped matching anything would look exactly like a rule with
  nothing to do.

  Options exist so tests need neither a cron tick nor a full database:

    * `:budget_bytes` — override the configured byte budget
    * `:dry_run` — measure and log without deleting anything
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    # Bound in order on purpose. Rule 1 shrinks the table that rule 2 measures,
    # so a budget enforced before the unreachable logs are gone would evict
    # reachable ones to make room for rows that were about to be deleted.
    unreachable = prune_unreachable(opts)
    over_budget = enforce_budget(opts)
    run_logs = clear_passing_run_logs(opts)

    report = %{unreachable: unreachable, over_budget: over_budget, run_logs: run_logs}

    total = report.unreachable.count + report.over_budget.count + report.run_logs.count

    if total > 0 do
      Logger.info(
        "LogRetention#{dry_run_suffix(opts)}: " <>
          "#{describe(report.unreachable, "unreachable system log")}, " <>
          "#{describe(report.over_budget, "over-budget system log")}, " <>
          "#{describe(report.run_logs, "passing run log")}"
      )
    end

    report
  end

  # ── Rule 1: unreachable per-system logs ────────────────────────────────────

  # The `DISTINCT ON` ordering mirrors `Portal.Catalog.latest_runs/1` exactly,
  # including the plain `DESC` — Ash's `:desc` renders to Ecto's `:desc`, which
  # is Postgres's NULLS FIRST. A run with no `finished_at` is therefore the
  # latest run in both places, and a log the page can still reach is never the
  # log this deletes.
  defp prune_unreachable(opts) do
    execute(
      opts,
      """
      WITH latest AS (
        SELECT DISTINCT ON (package_id) id
        FROM catalog_runs
        ORDER BY package_id, finished_at DESC, inserted_at DESC
      )
      DELETE FROM catalog_system_logs l
      USING catalog_system_results sr
      WHERE sr.id = l.system_result_id
        AND NOT EXISTS (SELECT 1 FROM latest WHERE latest.id = sr.run_id)
      RETURNING octet_length(l.body)
      """,
      [],
      """
      SELECT octet_length(l.body)
      FROM catalog_system_logs l
      JOIN catalog_system_results sr ON sr.id = l.system_result_id
      WHERE NOT EXISTS (
        SELECT 1 FROM (
          SELECT DISTINCT ON (package_id) id
          FROM catalog_runs
          ORDER BY package_id, finished_at DESC, inserted_at DESC
        ) latest WHERE latest.id = sr.run_id
      )
      """
    )
  end

  # ── Rule 2: the byte budget ────────────────────────────────────────────────

  # `running` is the size of this row plus everything newer, so `running >
  # budget` is "keeping this row would put the table over" — one window function
  # instead of a read, a sort and a second statement. Deliberately not `running
  # - bytes >= budget` ("everything newer already fills it"), which keeps the
  # row straddling the line and lets the table sit up to one log — 800 KB — over
  # a budget whose whole job is to be a ceiling.
  #
  # The tie-break on `id` keeps the order total: rows written by one ingest
  # share an `inserted_at` to the microsecond often enough to matter, and
  # without it the cut could fall in a different place than it measured.
  defp enforce_budget(opts) do
    budget = Keyword.get_lazy(opts, :budget_bytes, &configured_budget_bytes/0)

    ranked = """
    WITH ranked AS (
      SELECT id,
             octet_length(body) AS bytes,
             sum(octet_length(body)) OVER (ORDER BY inserted_at DESC, id DESC) AS running
      FROM catalog_system_logs
    )
    """

    execute(
      opts,
      ranked <>
        """
        DELETE FROM catalog_system_logs l
        USING ranked r
        WHERE l.id = r.id AND r.running > $1
        RETURNING r.bytes
        """,
      [budget],
      ranked <> "SELECT r.bytes FROM ranked r WHERE r.running > $1"
    )
  end

  # ── Rule 3: runner.log on passing runs ─────────────────────────────────────

  # `UPDATE ... RETURNING` hands back the new value, which is the NULL we just
  # wrote, so the size comes from the subquery that picked the rows.
  defp clear_passing_run_logs(opts) do
    select = """
    SELECT id, octet_length(log) AS bytes
    FROM catalog_runs
    WHERE overall_status = 'pass' AND log IS NOT NULL
    """

    execute(
      opts,
      """
      UPDATE catalog_runs r
      SET log = NULL
      FROM (#{select}) d
      WHERE r.id = d.id
      RETURNING d.bytes
      """,
      [],
      "SELECT bytes FROM (#{select}) d"
    )
  end

  # ── Plumbing ───────────────────────────────────────────────────────────────

  # Every rule returns one byte count per row it touched, so the same reducer
  # serves all three, and `:dry_run` swaps the statement for the SELECT that
  # measures the same set. A rule that raises is logged and counted as zero:
  # one broken statement must not cost the database the other two rules.
  defp execute(opts, statement, params, dry_statement) do
    sql = if Keyword.get(opts, :dry_run, false), do: dry_statement, else: statement

    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)

    Enum.reduce(rows, empty(), fn [bytes], acc ->
      %{count: acc.count + 1, bytes: acc.bytes + (bytes || 0)}
    end)
  rescue
    exception ->
      Logger.error("LogRetention statement failed: #{Exception.message(exception)}")
      empty()
  end

  defp configured_budget_bytes do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:budget_bytes, @default_budget_bytes)
  end

  defp describe(%{count: count, bytes: bytes}, label),
    do: "#{count} #{label}#{if count == 1, do: "", else: "s"} (#{mb(bytes)} MB)"

  defp dry_run_suffix(opts),
    do: if(Keyword.get(opts, :dry_run, false), do: " (dry run)", else: "")

  defp empty, do: %{count: 0, bytes: 0}

  defp mb(bytes), do: Float.round(bytes / 1024 / 1024, 1)
end
