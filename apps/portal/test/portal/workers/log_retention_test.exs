defmodule Portal.Workers.LogRetentionTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{Package, Run, SystemLog, SystemResult}
  alias Portal.Repo
  alias Portal.Workers.LogRetention

  # Rows are built directly rather than through `Portal.Catalog.Ingestion`
  # because every rule here is about the *relationship* between runs — which is
  # the latest, which log was written when — and ingest offers no handle on
  # either. A budget test in particular needs two logs whose `inserted_at`
  # differ by more than the microseconds a single test run would produce.

  defp package(name) do
    Ash.create!(Package, %{name: name, latest_version: "1.0.0"},
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp run(package, opts) do
    Ash.create!(
      Run,
      %{
        run_id: "rid-#{System.unique_integer([:positive])}",
        package_id: package.id,
        version_tested: "1.0.0",
        image_digest: "sha256:deadbeef",
        overall_status: Keyword.get(opts, :status, :fail),
        log: Keyword.get(opts, :log),
        finished_at: Keyword.get(opts, :finished_at)
      },
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp log(run, body, opts \\ []) do
    system_result =
      Ash.create!(
        SystemResult,
        %{
          run_id: run.id,
          system_pkg: "nerves_system_#{System.unique_integer([:positive])}",
          status: :fail
        },
        action: :create,
        domain: Portal.Catalog
      )

    log =
      Ash.create!(
        SystemLog,
        %{body: body, byte_size: byte_size(body), system_result_id: system_result.id},
        action: :create,
        domain: Portal.Catalog
      )

    # The budget orders by `inserted_at`, and rows created inside one test share
    # a timestamp closely enough that the order would be decided by the `id`
    # tie-break instead of by the age the test is trying to express. Ageing is
    # done in SQL so the value lands in the column's own type rather than
    # whatever Elixir struct Postgrex would have to cast.
    case Keyword.get(opts, :age_seconds) do
      nil ->
        log

      seconds ->
        Repo.query!(
          "UPDATE catalog_system_logs SET inserted_at = now() - make_interval(secs => $1) WHERE id = $2",
          [seconds, Ecto.UUID.dump!(log.id)]
        )

        log
    end
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp stored_log_ids do
    SystemLog |> Ash.read!(domain: Portal.Catalog) |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp reload_log(run_record) do
    Run |> Ash.get!(run_record.id, domain: Portal.Catalog) |> Map.fetch!(:log)
  end

  describe "unreachable per-system logs" do
    test "deletes the logs of a superseded run and keeps the latest run's" do
      package = package("jason")

      old = run(package, finished_at: ago(3600))
      new = run(package, finished_at: ago(60))

      stale = log(old, "old log")
      kept = log(new, "new log")

      assert %{} = LogRetention.run()

      assert stored_log_ids() == MapSet.new([kept.id])
      refute stale.id in stored_log_ids()
    end

    test "keeps the log when the package has only one run" do
      package = package("plug")
      kept = log(run(package, finished_at: ago(60)), "only log")

      assert %{} = LogRetention.run()

      assert stored_log_ids() == MapSet.new([kept.id])
    end

    test "a run that never finished is the latest run, matching latest_runs/1" do
      # Ash's `:desc` renders to plain SQL `DESC`, which in Postgres is NULLS
      # FIRST — so an unfinished run outranks a finished one on the package page
      # too, and its log is still reachable.
      package = package("ecto")

      finished = run(package, finished_at: ago(60))
      unfinished = run(package, finished_at: nil)

      stale = log(finished, "finished log")
      kept = log(unfinished, "in-flight log")

      assert %{} = LogRetention.run()

      assert stored_log_ids() == MapSet.new([kept.id])
      refute stale.id in stored_log_ids()
    end

    test "logs of another package's older run go too" do
      one = package("a")
      two = package("b")

      log(run(one, finished_at: ago(7200)), "a old")
      keep_a = log(run(one, finished_at: ago(60)), "a new")
      log(run(two, finished_at: ago(7200)), "b old")
      keep_b = log(run(two, finished_at: ago(60)), "b new")

      assert %{} = LogRetention.run()

      assert stored_log_ids() == MapSet.new([keep_a.id, keep_b.id])
    end
  end

  describe "byte budget" do
    test "evicts the oldest logs and keeps the newest" do
      # Each log belongs to its own package's only run, so rule 1 never fires
      # and what survives is the budget's decision alone.
      oldest =
        log(run(package("a"), finished_at: ago(60)), String.duplicate("a", 100), age_seconds: 300)

      middle =
        log(run(package("b"), finished_at: ago(60)), String.duplicate("b", 100), age_seconds: 200)

      newest =
        log(run(package("c"), finished_at: ago(60)), String.duplicate("c", 100), age_seconds: 100)

      # Room for two of the three: 300 bytes stored, 250 allowed, and the cut
      # falls where keeping the next row would go over rather than one row later.
      assert %{} = LogRetention.run(budget_bytes: 250)

      assert stored_log_ids() == MapSet.new([newest.id, middle.id])
      refute oldest.id in stored_log_ids()
    end

    test "keeps everything when the total is under the budget" do
      a = log(run(package("a"), finished_at: ago(60)), "short", age_seconds: 300)
      b = log(run(package("b"), finished_at: ago(60)), "also short", age_seconds: 100)

      assert %{} = LogRetention.run(budget_bytes: 10 * 1024)

      assert stored_log_ids() == MapSet.new([a.id, b.id])
    end

    test "a single log larger than the whole budget is still evicted" do
      # The budget is a hard ceiling: `running - bytes` is 0 for the newest row,
      # so a budget of 0 puts even that row past the line.
      only = log(run(package("a"), finished_at: ago(60)), String.duplicate("x", 100))

      assert %{} = LogRetention.run(budget_bytes: 0)

      refute only.id in stored_log_ids()
    end
  end

  describe "runner.log on passing runs" do
    test "clears the log of a passing run and keeps a failed run's" do
      package = package("jason")

      passing = run(package, status: :pass, log: "generated app", finished_at: ago(60))
      failed = run(package, status: :fail, log: "compilation error", finished_at: ago(3600))

      assert %{} = LogRetention.run()

      assert reload_log(passing) == nil
      assert reload_log(failed) == "compilation error"
    end

    test "leaves a passing run that already has no log alone" do
      passing = run(package("plug"), status: :pass, log: nil, finished_at: ago(60))

      assert %{} = LogRetention.run()

      assert reload_log(passing) == nil
    end
  end

  describe "dry run" do
    test "deletes nothing and clears nothing" do
      package = package("jason")

      old = run(package, finished_at: ago(3600))
      new = run(package, status: :pass, log: "generated app", finished_at: ago(60))

      stale = log(old, String.duplicate("s", 100))
      kept = log(new, String.duplicate("k", 100))

      assert %{} = LogRetention.run(dry_run: true, budget_bytes: 0)

      assert stored_log_ids() == MapSet.new([stale.id, kept.id])
      assert reload_log(new) == "generated app"
    end

    test "still reports the counts and bytes it would have removed" do
      package = package("jason")
      log(run(package, finished_at: ago(3600)), String.duplicate("s", 100))
      log(run(package, finished_at: ago(60)), String.duplicate("k", 100))

      report = LogRetention.run(dry_run: true)

      assert report.unreachable == %{count: 1, bytes: 100}
    end

    test "the measured set matches the deleted set" do
      # The dry run and the real run are two different SQL statements; the whole
      # point of the option is that they select the same rows.
      package = package("jason")
      log(run(package, finished_at: ago(3600)), String.duplicate("s", 100))
      log(run(package, finished_at: ago(60)), String.duplicate("k", 100))

      measured = LogRetention.run(dry_run: true)
      deleted = LogRetention.run()

      assert measured.unreachable == deleted.unreachable
    end
  end

  describe "perform/1" do
    test "runs every rule from an Oban job" do
      package = package("jason")

      old = run(package, finished_at: ago(3600))
      new = run(package, status: :pass, log: "generated app", finished_at: ago(60))

      stale = log(old, "old log")
      kept = log(new, "new log")

      assert :ok = LogRetention.perform(%Oban.Job{args: %{}})

      assert stored_log_ids() == MapSet.new([kept.id])
      refute stale.id in stored_log_ids()
      assert reload_log(new) == nil
    end
  end
end
