defmodule Portal.Workers.UpdateCheckTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  alias Portal.Catalog.Package
  alias Portal.Catalog.Run
  alias Portal.Repo
  alias Portal.Workers.UpdateCheck

  setup do
    Application.put_env(:portal, :hex_registry_source, __MODULE__.StubRegistry)

    on_exit(fn ->
      Application.delete_env(:portal, :hex_registry_source)
      Application.delete_env(:portal, UpdateCheck)
    end)

    :ok
  end

  # Stands in for `Portal.HexRegistry`. The worker runs in the test process, so
  # the canned answer can live in the process dictionary.
  defmodule StubRegistry do
    def snapshot do
      send(self(), :asked_registry)

      case Process.get(:hex_answer, {:ok, []}) do
        {:ok, rows} -> {:ok, rows |> Enum.with_index() |> Enum.map(&normalise/1)}
        other -> other
      end
    end

    # Timestamps descend with list position, so the first row written in a test
    # is the newest package. The real registry carries no ordering at all and
    # the worker sorts on `updated_at`; writing the rows newest-first here keeps
    # the ordering tests honest rather than letting them pass on list order.
    defp normalise({{name, version}, index}) do
      %{
        name: name,
        latest_version: version,
        updated_at: DateTime.add(DateTime.utc_now(), -index, :second)
      }
    end

    defp normalise({{name, version, updated_at}, _index}),
      do: %{name: name, latest_version: version, updated_at: updated_at}
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

    # The whole point of reading the registry rather than a window: a package
    # that drifted long ago is still visible, so nothing has to be remembered
    # between runs and a missed tick repairs itself.
    test "queues a package whose drift is far older than any window would cover" do
      package("ancient", "1.0.0")
      hex_says([{"ancient", "2.0.0", ~U[2020-01-01 00:00:00Z]}])

      assert {:ok, %{moved: 1, enqueued: 1}} = UpdateCheck.run()
      assert queued_packages() == ["ancient"]
    end

    # Tracked packages are looked up in the registry rather than the other way
    # round, so a name hex no longer publishes must simply be absent from the
    # comparison -- not crash, and not read as drift.
    test "ignores a tracked package the registry does not carry" do
      package("withdrawn", "1.0.0")
      hex_says([{"other", "1.0.0"}])

      assert {:ok, %{moved: 0, enqueued: 0}} = UpdateCheck.run()
      assert queued_packages() == []
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
      refute_received :asked_registry
    end

    # Not the shipped default, which is on -- this is the config block having
    # gone missing altogether. The fallback stays `false` because the one thing
    # a lost config must not do is start sending hex.pm traffic on its own.
    test "sends nothing when the config block is absent entirely" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.delete_env(:portal, UpdateCheck)

      assert :ok = perform_job(UpdateCheck, %{})
      refute_received :asked_registry
    end

    test "runs the check once enabled" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: true)

      assert {:ok, %{enqueued: 1}} = perform_job(UpdateCheck, %{})
      assert queued_packages() == ["alpha"]
    end

    # The gate exists to stop the *schedule* sending hex.pm traffic. An admin
    # standing at the page and pressing the button is not the schedule, and a
    # switched-off check they cannot run on purpose is a check they cannot
    # diagnose.
    test "a manual run happens even while the schedule is switched off" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: false)

      assert {:ok, %{enqueued: 1}} = perform_job(UpdateCheck, %{"manual" => true})
      assert queued_packages() == ["alpha"]
    end

    test "a manual dry run reports the drift and queues nothing" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: false)

      assert {:ok, %{moved: 1, enqueued: 0}} =
               perform_job(UpdateCheck, %{"manual" => true, "dry_run" => true})

      assert queued_packages() == []
    end

    test "records the run's numbers on the job that produced them" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: true)

      job = Oban.insert!(UpdateCheck.new(%{"manual" => true}))
      assert {:ok, _summary} = UpdateCheck.perform(job)

      meta = Repo.one(from(j in Oban.Job, where: j.id == ^job.id, select: j.meta))

      assert meta["seen"] == 1
      assert meta["moved"] == 1
      assert meta["enqueued"] == 1
      assert meta["dry_run"] == false

      # String keys throughout. This round-trips through jsonb, so merging atom
      # keys into what comes back would silently give the map two of everything.
      assert Enum.all?(Map.keys(meta), &is_binary/1)
    end

    test "a dry run says so in what it recorded" do
      package("alpha", "1.0.0")
      hex_says([{"alpha", "1.1.0"}])
      Application.put_env(:portal, UpdateCheck, enabled: true)

      job = Oban.insert!(UpdateCheck.new(%{"manual" => true, "dry_run" => true}))
      assert {:ok, _summary} = UpdateCheck.perform(job)

      meta = Repo.one(from(j in Oban.Job, where: j.id == ^job.id, select: j.meta))

      # Without this the panel would show "0 queued" for a dry run and for a
      # run that found nothing to do, which are opposite situations.
      assert meta["dry_run"] == true
      assert meta["moved"] == 1
      assert meta["enqueued"] == 0
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

  describe "run/1 without a per-run cap" do
    test "queues every eligible update, including more than the old five-package limit" do
      for n <- 1..8, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..8, do: {"pkg#{n}", "1.1.0"})

      assert {:ok, %{seen: 8, moved: 8, enqueued: 8}} = UpdateCheck.run()
      assert length(queued_packages()) == 8
    end

    test "already queued candidates do not prevent other updates from being queued" do
      for n <- 1..8, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..5, do: {"pkg#{n}", "1.1.0"})
      assert {:ok, %{enqueued: 5}} = UpdateCheck.run()

      now = DateTime.utc_now()
      hex_says(for n <- 1..8, do: {"pkg#{n}", "1.1.0", DateTime.add(now, n - 100, :second)})
      assert {:ok, %{moved: 8, enqueued: 3}} = UpdateCheck.run()
      assert length(queued_packages()) == 8
    end

    test "schedules every update oldest first, with metadata lookups one second apart" do
      for name <- ["newest", "middle", "oldest"], do: passing_package(name, "1.0.0")
      hex_says([{"newest", "1.1.0"}, {"middle", "1.1.0"}, {"oldest", "1.1.0"}])

      assert {:ok, %{enqueued: 3}} = UpdateCheck.run()
      jobs = Enum.sort_by(backfill_jobs(), & &1.id)
      assert Enum.map(jobs, & &1.args["package"]) == ["oldest", "middle", "newest"]

      for [first, second] <- Enum.chunk_every(jobs, 2, 1, :discard) do
        assert DateTime.diff(second.scheduled_at, first.scheduled_at, :millisecond) >= 1_000
      end
    end

    test "orders dated updates chronologically and undated updates last" do
      for name <- ["first", "second", "undated"], do: passing_package(name, "1.0.0")

      hex_says([
        {"undated", "1.1.0", nil},
        {"first", "1.1.0", ~U[2026-01-01 00:00:00Z]},
        {"second", "1.1.0", ~U[2025-12-31 00:00:00Z]}
      ])

      assert {:ok, %{enqueued: 3}} = UpdateCheck.run()

      assert backfill_jobs() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.args["package"]) ==
               ["second", "first", "undated"]
    end

    test "a leftover cap setting does not suppress updates" do
      for n <- 1..8, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..8, do: {"pkg#{n}", "1.1.0"})
      Application.put_env(:portal, UpdateCheck, enabled: true, max_per_run: 1)

      assert {:ok, %{moved: 8, enqueued: 8}} = UpdateCheck.run()
    end

    test "dry_run reports every eligible update without queueing any" do
      for n <- 1..8, do: passing_package("pkg#{n}", "1.0.0")
      hex_says(for n <- 1..8, do: {"pkg#{n}", "1.1.0"})

      assert {:ok, %{moved: 8, enqueued: 0}} = UpdateCheck.run(dry_run: true)
      assert queued_packages() == []
    end
  end
end
