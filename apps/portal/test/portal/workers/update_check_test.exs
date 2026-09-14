defmodule Portal.Workers.UpdateCheckTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  alias Portal.Catalog.Package
  alias Portal.Catalog.Run
  alias Portal.Repo
  alias Portal.Workers.UpdateCheck

  setup do
    Application.put_env(:portal, :hex_updates_source, __MODULE__.StubUpdates)

    on_exit(fn ->
      Application.delete_env(:portal, :hex_updates_source)
      Application.delete_env(:portal, UpdateCheck)
    end)

    :ok
  end

  # Stands in for `Portal.HexPm`. The worker runs in the test process, so the
  # canned answer can live in the process dictionary.
  defmodule StubUpdates do
    def recently_updated(opts) do
      send(self(), {:asked_since, Keyword.fetch!(opts, :since)})

      case Process.get(:hex_answer, {:ok, []}) do
        {:ok, rows} -> {:ok, Enum.map(rows, &normalise/1)}
        other -> other
      end
    end

    defp normalise({name, version}),
      do: %{name: name, latest_version: version, updated_at: DateTime.utc_now()}
  end

  defp hex_says(rows), do: Process.put(:hex_answer, {:ok, rows})

  defp hex_fails(reason), do: Process.put(:hex_answer, {:error, reason})

  defp package(name, latest_version) do
    Ash.create!(Package, %{name: name, latest_version: latest_version},
      action: :create,
      domain: Portal.Catalog
    )
  end

  # The filter only skips a patch bump when the package's newest run passed, so
  # most of these tests need a run on record. `package/2` deliberately creates
  # none -- a package with no run reads as not-passing, and is rebuilt on any
  # bump.
  defp run(package, overall_status, opts \\ []) do
    Ash.create!(
      Run,
      %{
        run_id: "#{package.name}-#{System.unique_integer([:positive])}",
        package_id: package.id,
        version_tested: package.latest_version || "0.0.0",
        overall_status: overall_status,
        finished_at: Keyword.get(opts, :finished_at, DateTime.utc_now())
      },
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp passing_package(name, latest_version) do
    package = package(name, latest_version)
    run(package, :pass)
    package
  end

  defp backfill_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Backfill"))
  end

  defp queued_packages, do: backfill_jobs() |> Enum.map(& &1.args["package"]) |> Enum.sort()

  describe "run/1" do
    test "queues a rebuild when hex has a newer version than the one on record" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])

      assert {:ok, %{seen: 1, moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "queues nothing when the version on record already matches" do
      package("alpha", "1.1.0")
      hex_says([{"alpha", "1.1.0"}])

      assert {:ok, %{seen: 1, moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    # hex.pm updates ~130 packages a day across a registry we cover about a
    # seventh of. Queueing the rest would be seeding new packages, which is
    # `Portal.UpstreamBackfill`'s job and a very different amount of work.
    test "ignores packages the catalogue does not track" do
      hex_says([{"never_heard_of_it", "3.0.0"}])

      assert {:ok, %{seen: 1, moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    test "picks the moved ones out of a mixed batch" do
      package("moved", "1.0.0")
      package("same", "2.0.0")
      hex_says([{"moved", "1.1.0"}, {"same", "2.0.0"}, {"untracked", "9.9.9"}])

      assert {:ok, %{seen: 3, moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["moved"]
    end

    # A tracked package with nothing on record has never produced a result, so
    # it is as stale as one whose version moved and wants the same rebuild.
    test "queues a tracked package that has no version on record" do
      package("untested", nil)
      hex_says([{"untested", "1.0.0"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["untested"]
    end

    test "counts a package already queued by an earlier run as moved but not enqueued" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])

      assert {:ok, %{enqueued: 1}} = UpdateCheck.run()
      # `Backfill` is unique per package per day, so the overlapping window every
      # later run sees must not insert a second job.
      assert {:ok, %{moved: 1, enqueued: 0}} = UpdateCheck.run()
      assert length(backfill_jobs()) == 1
    end

    test "dry_run reports what would be queued without queueing it" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])

      assert {:ok, %{moved: 1, enqueued: 0}} = UpdateCheck.run(dry_run: true)
      assert queued_packages() == []
    end

    test "asks hex for the configured window" do
      hex_says([])

      assert {:ok, _} = UpdateCheck.run(lookback_ms: :timer.hours(6))

      assert_received {:asked_since, since}
      hours = DateTime.diff(DateTime.utc_now(), since, :second) / 3600
      assert_in_delta hours, 6, 0.1
    end

    test "a hex failure is reported rather than counted as nothing to do" do
      package("alpha", "1.0.0")
      hex_fails(:hex_api_unavailable)

      assert {:error, :hex_api_unavailable} = UpdateCheck.run()
      assert queued_packages() == []
    end
  end

  describe "perform/1" do
    test "does nothing at all while disabled" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: false)

      assert :ok = perform_job(UpdateCheck, %{})
      assert queued_packages() == []
      # Disabled has to mean "sends hex.pm nothing", not "throws the answer away".
      refute_received {:asked_since, _}
    end

    test "defaults to disabled when nothing is configured" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.delete_env(:portal, UpdateCheck)

      assert :ok = perform_job(UpdateCheck, %{})
      refute_received {:asked_since, _}
    end

    test "runs the check once enabled" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: true)

      assert {:ok, %{enqueued: 1}} = perform_job(UpdateCheck, %{})
      assert queued_packages() == ["alpha"]
    end

    test "uses the configured lookback window" do
      hex_says([])
      Application.put_env(:portal, UpdateCheck, enabled: true, lookback_ms: :timer.hours(12))

      assert {:ok, _} = perform_job(UpdateCheck, %{})

      assert_received {:asked_since, since}
      hours = DateTime.diff(DateTime.utc_now(), since, :second) / 3600
      assert_in_delta hours, 12, 0.1
    end
  end

  describe "run/1 version filter" do
    # 45% of the drift measured against the real catalogue is patch-only, and a
    # patch release is the one least likely to move anything we measure.
    test "a patch bump on a passing package is not queued" do
      passing_package("alpha", "1.2.3")
      hex_says([{"alpha", "1.2.4"}])

      assert {:ok, %{seen: 1, moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    # The exception that makes the filter safe to ship: a red badge has to be
    # clearable, and a patch release on a failing package is usually the
    # maintainer fixing exactly what we flagged.
    test "a patch bump on a failing package is queued" do
      package = package("alpha", "1.2.3")
      run(package, :fail)
      hex_says([{"alpha", "1.2.4"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "a patch bump on a skipped package is queued" do
      package = package("alpha", "1.2.3")
      run(package, :skipped)
      hex_says([{"alpha", "1.2.4"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "a patch bump on a package with no run at all is queued" do
      package("alpha", "1.2.3")
      hex_says([{"alpha", "1.2.4"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    # Only the newest run decides. A package that failed once and has passed
    # since is a passing package, and its patch releases are skipped like any
    # other.
    test "an older failing run does not override a newer passing one" do
      package = package("alpha", "1.2.3")
      run(package, :fail, finished_at: DateTime.add(DateTime.utc_now(), -2, :hour))
      run(package, :pass)
      hex_says([{"alpha", "1.2.4"}])

      assert {:ok, %{moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    test "0.1.1 -> 0.1.2 on a passing package is not queued" do
      passing_package("alpha", "0.1.1")
      hex_says([{"alpha", "0.1.2"}])

      assert {:ok, %{moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    test "0.1.0 -> 0.2.0 on a passing package is queued" do
      passing_package("alpha", "0.1.0")
      hex_says([{"alpha", "0.2.0"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "a major bump on a passing package is queued" do
      passing_package("alpha", "1.2.3")
      hex_says([{"alpha", "2.0.0"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    # Every number before the `-` is unchanged, so a naive major/minor/patch
    # comparison calls this insignificant. It is the opposite: the stable
    # release is the one worth measuring.
    test "a prerelease graduating to stable is queued" do
      passing_package("alpha", "0.19.0-beta.2")
      hex_says([{"alpha", "0.19.0"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "prerelease churn inside one patch version is not queued" do
      passing_package("alpha", "0.19.0-beta.2")
      hex_says([{"alpha", "0.19.0-beta.3"}])

      assert {:ok, %{moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
    end

    test "a version we cannot parse is queued rather than silently skipped" do
      passing_package("alpha", "2016d")
      hex_says([{"alpha", "2016e"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end

    test "an unparseable version on the hex side is queued too" do
      passing_package("alpha", "1.2.3")
      hex_says([{"alpha", "not-a-version"}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["alpha"]
    end
  end

  describe "run/1 per-run cap" do
    test "queues at most max_per_run and reports the rest as deferred" do
      for n <- 1..4, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..4, do: {"pkg#{n}", "1.1.0"})

      assert {:ok, %{seen: 4, moved: 4, enqueued: 2, deferred: 2}} =
               UpdateCheck.run(max_per_run: 2)

      assert length(queued_packages()) == 2
    end

    # The ordering rule, and the reason the cap is safe. hex.pm hands back the
    # newest update first, and the window is the only thing keeping a deferred
    # package alive -- so the budget goes to the end of the list, the work
    # closest to falling past the cutoff. Newest-first would starve exactly the
    # packages about to disappear.
    test "spends the budget oldest first" do
      for name <- ["newest", "middle", "oldest"], do: passing_package(name, "1.0.0")
      hex_says([{"newest", "1.1.0"}, {"middle", "1.1.0"}, {"oldest", "1.1.0"}])

      assert {:ok, %{moved: 3, enqueued: 1, deferred: 2}} = UpdateCheck.run(max_per_run: 1)
      assert queued_packages() == ["oldest"]
    end

    test "nothing is deferred when the cap does not bind" do
      passing_package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])

      assert {:ok, %{moved: 1, enqueued: 1, deferred: 0}} = UpdateCheck.run(max_per_run: 5)
      assert queued_packages() == ["alpha"]
    end

    test "honours a configured max_per_run" do
      for n <- 1..3, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..3, do: {"pkg#{n}", "1.1.0"})
      Application.put_env(:portal, UpdateCheck, enabled: true, max_per_run: 1)

      assert {:ok, %{moved: 3, enqueued: 1, deferred: 2}} = UpdateCheck.run()
      assert length(queued_packages()) == 1
    end

    # The cap shapes what gets queued, not what gets counted: `moved` is the
    # honest size of the backlog, and a caller watching it would otherwise see
    # the cap as the work disappearing.
    test "dry_run still reports the full moved count under a cap" do
      for n <- 1..3, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..3, do: {"pkg#{n}", "1.1.0"})

      assert {:ok, %{moved: 3, enqueued: 0, deferred: 2}} =
               UpdateCheck.run(max_per_run: 1, dry_run: true)

      assert queued_packages() == []
    end
  end
end
