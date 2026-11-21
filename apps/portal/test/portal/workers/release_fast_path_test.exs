defmodule Portal.Workers.ReleaseFastPathTest do
  # Not async: it swaps the `Portal.Toolchains` and worker application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.PrecompiledFixtures

  alias Portal.Workers.{ReleaseFastPath, ToolchainBuild, ToolchainSweep}

  @built "2026-11-10T00:00:00Z"
  @now ~U[2026-11-21 12:00:00Z]

  defmodule StubRegistry do
    def snapshot(_opts) do
      send(self(), :asked_registry)
      if hook = Process.get(:registry_hook), do: hook.()
      Process.get(:hex_answer, {:ok, []})
    end
  end

  setup do
    toolchains = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(toolchains,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}],
        builder_version: 1
      )
    )

    fast_path = Application.get_env(:portal, ReleaseFastPath, [])
    Application.put_env(:portal, ReleaseFastPath, enabled: true, min_dependents: 2)
    Application.put_env(:portal, :hex_registry_source, StubRegistry)

    on_exit(fn ->
      Application.put_env(:portal, Portal.Toolchains, toolchains)
      Application.put_env(:portal, ReleaseFastPath, fast_path)
      Application.delete_env(:portal, :hex_registry_source)
    end)

    :ok
  end

  defp entry(name, versions, updated_at) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: updated_at,
      versions: versions,
      retired: []
    }
  end

  defp release(version, deps) do
    deps =
      for {package, requirement} <- deps,
          do: %{package: package, requirement: requirement, optional: false, repository: "hexpm"}

    %{version: version, retired?: false, outer_checksum: nil, deps: deps}
  end

  defp locking!(name, dep, version) do
    ingest_toolchain_build(name, "0.4.0",
      deps_lock: %{dep => %{"version" => version, "checksum" => "c-#{version}"}},
      finished_at: @built
    )
  end

  defp name, do: "fast_#{System.unique_integer([:positive])}"

  describe "offer/2" do
    test "offers a release that changed in the window and that enough dependents lock behind" do
      [a, b, c] = [name(), name(), name()]
      locking!(a, "popular", "1.0.0")
      locking!(b, "popular", "1.0.0")
      locking!(c, "lonely", "1.0.0")
      locking!(name(), "stale", "1.0.0")
      locking!(name(), "stale", "1.0.0")

      registry = [
        entry("popular", ["1.0.0", "1.1.0"], DateTime.add(@now, -1800, :second)),
        entry("lonely", ["1.0.0", "1.1.0"], DateTime.add(@now, -1800, :second)),
        entry("stale", ["1.0.0", "1.1.0"], DateTime.add(@now, -5 * 3600, :second))
      ]

      assert ReleaseFastPath.offer(registry, now: @now) == 1

      assert [%{args: %{"package" => "popular", "version" => "1.1.0"}}] =
               all_enqueued(worker: ReleaseFastPath)

      # The same release once.
      assert ReleaseFastPath.offer(registry, now: @now) == 0
    end

    test "a release the dependents already lock is not offered" do
      locking!(name(), "popular", "1.1.0")
      locking!(name(), "popular", "1.1.0")

      registry = [entry("popular", ["1.0.0", "1.1.0"], @now)]

      assert ReleaseFastPath.offer(registry, now: @now) == 0
    end

    test "a prerelease is no release to rebuild for" do
      locking!(name(), "popular", "1.0.0")
      locking!(name(), "popular", "1.0.0")

      assert ReleaseFastPath.offer([entry("popular", ["1.0.0", "1.1.0-rc.1"], @now)], now: @now) ==
               0
    end

    # Review R8: the update check calls this after its own writes; a failed
    # query must not fail and retry the whole check.
    test "a query that fails offers nothing instead of raising" do
      Application.put_env(:portal, ReleaseFastPath, enabled: true, min_dependents: "many")
      locking!(name(), "popular", "1.0.0")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ReleaseFastPath.offer([entry("popular", ["1.0.0", "1.1.0"], @now)], now: @now) ==
                   0
        end)

      assert log =~ "Release fast path could not offer"
    end

    test "offers nothing while switched off" do
      Application.put_env(:portal, ReleaseFastPath, enabled: false, min_dependents: 2)
      locking!(name(), "popular", "1.0.0")
      locking!(name(), "popular", "1.0.0")

      assert ReleaseFastPath.offer([entry("popular", ["1.0.0", "1.1.0"], @now)], now: @now) == 0
    end
  end

  describe "perform/1" do
    # `names` 0.4.0 on hex, each locking `certifi` 2.18.0 while 2.19.0 is out.
    defp certifi_release(names) do
      for name <- names, do: locking!(name, "certifi", "2.18.0")

      Process.put(
        :hex_answer,
        {:ok,
         [entry("certifi", ["2.18.0", "2.19.0"], ~U[2026-11-12 00:00:00Z])] ++
           for(name <- names, do: entry(name, ["0.4.0"], ~U[2026-11-01 00:00:00Z]))}
      )

      put_releases(
        Map.new(names, &{&1, [release("0.4.0", [{"certifi", "~> 2.18"}])]})
        |> Map.put("certifi", [release("2.18.0", []), release("2.19.0", [])])
      )
    end

    defp put_releases(releases) do
      current = Process.get({Portal.Test.FakeHexDeps, :releases}, %{})
      Process.put({Portal.Test.FakeHexDeps, :releases}, Map.merge(current, releases))
    end

    # The builds of `jobs` ran: their jobs are done, and each row records the
    # attempt, as a rebuild that landed or failed does.
    defp ran!(jobs) do
      ids = Enum.map(jobs, & &1.id)
      Portal.Repo.update_all(from(j in Oban.Job, where: j.id in ^ids), set: [state: "completed"])
      names = Enum.map(jobs, & &1.args["package"])

      Portal.Repo.query!(
        """
        UPDATE catalog_toolchain_builds t SET attempted_at = now() AT TIME ZONE 'utc'
        FROM catalog_packages p WHERE p.id = t.package_id AND p.name = ANY($1)
        """,
        [names]
      )
    end

    # The test config logs warnings only; these lines are info.
    defp info_log(fun) do
      level = Logger.level()
      Logger.configure(level: :info)

      try do
        ExUnit.CaptureLog.capture_log([level: :info], fun)
      after
        Logger.configure(level: level)
      end
    end

    defp put_certifi_versions(versions, opts \\ []) do
      {:ok, registry} = Process.get(:hex_answer)

      registry =
        Enum.map(registry, fn
          %{name: "certifi"} = e ->
            %{
              e
              | versions: versions,
                latest_version: List.last(versions),
                retired: Keyword.get(opts, :retired, [])
            }

          e ->
            e
        end)

      Process.put(:hex_answer, {:ok, registry})
    end

    defp flush_registry_reads do
      receive do
        :asked_registry -> flush_registry_reads()
      after
        0 -> :ok
      end
    end

    defp lock_args, do: Tuple.to_list(ReleaseFastPath.lock_key())
    defp lock_sql, do: "SELECT pg_advisory_lock($1, $2)"
    defp try_lock_sql, do: "SELECT pg_try_advisory_lock($1, $2)"
    defp unlock_sql, do: "SELECT pg_advisory_unlock($1, $2)"

    # A second database session, outside the test's sandbox.
    defp session_config do
      Portal.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:pool_size, 1)
    end

    defp fast_path_builds,
      do:
        all_enqueued(worker: ToolchainBuild)
        |> Enum.filter(&(&1.args["reason"] == "release_fast_path"))

    test "rebuilds the builds that lock the package at priority 2, and forces no sweep" do
      [dependent, other] = [name(), name()]
      certifi_release([dependent])
      locking!(other, "jason", "1.0.0")

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert [job] = all_enqueued(worker: ToolchainBuild)
      assert job.priority == 2

      assert %{
               "package" => ^dependent,
               "reason" => "release_fast_path",
               "drift" => [%{"dep" => "certifi", "to" => "2.19.0"}]
             } = job.args

      assert all_enqueued(worker: ToolchainSweep) == []
    end

    test "two big releases in one hour share the budget, and what does not fit carries over" do
      Application.put_env(:portal, ReleaseFastPath,
        enabled: true,
        budget: 3,
        max_per_release: 2
      )

      certifi_names = for _ <- 1..3, do: name()
      certifi_release(certifi_names)

      jason_names = for _ <- 1..3, do: name()
      for name <- jason_names, do: locking!(name, "jason", "1.0.0")

      {:ok, registry} = Process.get(:hex_answer)

      Process.put(
        :hex_answer,
        {:ok,
         registry ++
           [entry("jason", ["1.0.0", "1.1.0"], ~U[2026-11-12 00:00:00Z])] ++
           for(name <- jason_names, do: entry(name, ["0.4.0"], ~U[2026-11-01 00:00:00Z]))}
      )

      put_releases(
        Map.new(jason_names, &{&1, [release("0.4.0", [{"jason", "~> 1.0"}])]})
        |> Map.put("jason", [release("1.0.0", []), release("1.1.0", [])])
      )

      # certifi takes its share of the budget and comes back for the rest.
      assert {:snooze, 3600} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert length(fast_path_builds()) == 2

      # jason gets what is left of the budget, and comes back too.
      assert {:snooze, 3600} =
               perform_job(ReleaseFastPath, %{"package" => "jason", "version" => "1.1.0"})

      assert length(fast_path_builds()) == 3

      # A full budget queues nothing and reads nothing.
      flush_registry_reads()

      assert {:snooze, 3600} =
               perform_job(ReleaseFastPath, %{"package" => "jason", "version" => "1.1.0"})

      assert length(fast_path_builds()) == 3
      refute_received :asked_registry

      # Once the queued builds have run, the remainder carries over: each
      # release queues what is left and finishes.
      first = fast_path_builds()
      ran!(first)

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert {:ok, %{enqueued: 2}} =
               perform_job(ReleaseFastPath, %{"package" => "jason", "version" => "1.1.0"})

      rebuilt = for job <- first ++ fast_path_builds(), do: job.args["package"]
      assert Enum.sort(rebuilt) == Enum.sort(certifi_names ++ jason_names)
    end

    # By its age, not by its snoozes: a snooze for the lock (below) is no
    # hour of carry-over.
    test "a carried-over release gives up carry_over_hours after it was queued" do
      Application.put_env(:portal, ReleaseFastPath, enabled: true, budget: 0, carry_over_hours: 2)
      args = %{"package" => "certifi", "version" => "2.19.0"}
      now = DateTime.utc_now()

      young = %Oban.Job{args: args, meta: %{"snoozed" => 50}, inserted_at: now}
      assert {:snooze, 3600} = ReleaseFastPath.perform(young)

      old = %Oban.Job{args: args, meta: %{}, inserted_at: DateTime.add(now, -2 * 3600, :second)}
      assert {:cancel, _} = ReleaseFastPath.perform(old)
    end

    # Review F1: runs at once each read the same room, so the budget was soft.
    # The lock lives on a connection of its own, outside the pool and so
    # outside this test's sandbox: `other` and the run are two real
    # sessions. That the run's own statements go through the pool, and not
    # through the lock's connection, the sandbox cannot show (it sends every
    # pool query to its one connection); `lock/0` holds that by construction.
    test "only one job runs at a time: another holding the lock snoozes it a minute" do
      certifi_release([name()])
      # Linked: should the test fail, the session closes with it and so lets
      # its lock go.
      {:ok, other} = Postgrex.start_link(session_config())

      Postgrex.query!(other, lock_sql(), lock_args())
      flush_registry_reads()

      assert {:snooze, seconds} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert seconds in 60..90
      assert fast_path_builds() == []
      refute_received :asked_registry

      Postgrex.query!(other, unlock_sql(), lock_args())

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      # The run let the lock go: the other session takes it at once.
      assert %{rows: [[true]]} = Postgrex.query!(other, try_lock_sql(), lock_args())

      GenServer.stop(other)
    end

    # Re-review H3: up to an `:intake` queue's worth of waiting jobs wake
    # together; each one used to open a Postgres connection of its own to
    # find the lock busy. The pool answers that now, and the lock's own
    # connection is opened only to take it. Here that connection points at
    # a port nothing listens on, so opening it would log a failure.
    test "a job that finds the lock busy opens no connection of its own, and wakes jittered" do
      {:ok, other} = Postgrex.start_link(session_config())
      Postgrex.query!(other, lock_sql(), lock_args())
      Application.put_env(:portal, ReleaseFastPath, enabled: true, lock_connection: [port: 1])

      snoozes =
        for _ <- 1..20 do
          log =
            ExUnit.CaptureLog.capture_log(fn ->
              assert {:snooze, seconds} =
                       ReleaseFastPath.perform(%Oban.Job{
                         args: %{"package" => "certifi", "version" => "2.19.0"},
                         inserted_at: DateTime.utc_now()
                       })

              send(self(), {:snoozed, seconds})
            end)

          assert log == ""
          assert_received {:snoozed, seconds}
          seconds
        end

      assert Enum.all?(snoozes, &(&1 in 60..90))
      assert length(Enum.uniq(snoozes)) > 1

      GenServer.stop(other)
    end

    # The check through the pool is only a shortcut: when it finds the lock
    # free but the lock's own connection cannot take it, the job waits too.
    test "a lock connection that fails is a wait, not a run, and is logged as such" do
      Application.put_env(:portal, ReleaseFastPath, enabled: true, lock_connection: [port: 1])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:snooze, seconds} =
                   ReleaseFastPath.perform(%Oban.Job{
                     args: %{"package" => "certifi", "version" => "2.19.0"},
                     inserted_at: DateTime.utc_now()
                   })

          assert seconds in 60..90
        end)

      assert log =~ "Release fast path could not reach its lock"
      assert fast_path_builds() == []
    end

    # Re-review H4: when the lock's session ends during a run (an operator's
    # pg_terminate_backend, a dropped socket), DBConnection reconnects
    # without the lock, and another job could take it. The run cannot undo
    # that, but it says so.
    test "a run whose lock was lost says so at the end" do
      certifi_release([name()])

      Process.put(:registry_hook, fn ->
        Portal.Repo.query!(
          """
          SELECT pg_terminate_backend(pid) FROM pg_locks
          WHERE locktype = 'advisory' AND granted AND classid = $1 AND objid = $2
            AND objsubid = 2
          """,
          lock_args()
        )

        # Long enough for DBConnection to reconnect the lock's connection.
        Process.sleep(1_500)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{enqueued: 1}} =
                   perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})
        end)

      assert log =~ "Release fast path lost its lock during the run"
    end

    # Re-review H6: a job that finds the lock busy gives up at the same age
    # as one that carries over.
    test "a job that finds the lock busy gives up carry_over_hours after it was queued" do
      {:ok, other} = Postgrex.start_link(session_config())
      Postgrex.query!(other, lock_sql(), lock_args())
      args = %{"package" => "certifi", "version" => "2.19.0"}
      old = DateTime.add(DateTime.utc_now(), -49 * 3600, :second)

      assert {:cancel, "release fast path for certifi 2.19.0 gave up: locked"} =
               ReleaseFastPath.perform(%Oban.Job{args: args, inserted_at: old})

      GenServer.stop(other)
    end

    # Re-review G1: inside `Repo.checkout/2`, finite or not, a statement gets
    # no deadline of its own (DBConnection sets one only at checkout), so a
    # blocked statement held the lock, the `:intake` slot and the connection
    # for as long as the block lasted. The run's statements keep theirs.
    test "a statement in the run keeps its own timeout, and the lock goes with the run" do
      certifi_release([name()])

      Process.put(:registry_hook, fn ->
        Portal.Repo.query!("SELECT pg_sleep(1.5)", [], timeout: 200)
      end)

      {elapsed, raised} =
        :timer.tc(fn ->
          try do
            ReleaseFastPath.perform(%Oban.Job{
              args: %{"package" => "certifi", "version" => "2.19.0"},
              inserted_at: DateTime.utc_now()
            })
          rescue
            error in [DBConnection.ConnectionError, Postgrex.Error] -> error
          end
        end)

      # The statement's own timeout: the client gives up, or the cancel it
      # sends reaches the server first, whichever wins under load.
      assert match?(%DBConnection.ConnectionError{}, raised) or
               match?(%Postgrex.Error{postgres: %{code: :query_canceled}}, raised)

      assert div(elapsed, 1000) < 1_200

      {:ok, other} = Postgrex.start_link(session_config())
      assert %{rows: [[true]]} = Postgrex.query!(other, try_lock_sql(), lock_args())
      GenServer.stop(other)
    end

    # Re-review G4: a single bigint key shares its space with the
    # `hashtext` identity locks (`pg_advisory_xact_lock(hashtext(...))`);
    # the two-key form has a space of its own.
    test "the lock is the two-key form, apart from the hashtext identity locks" do
      assert {classid, objid} = ReleaseFastPath.lock_key()
      assert classid in -2_147_483_648..2_147_483_647
      assert objid in -2_147_483_648..2_147_483_647

      # A one-key lock on any number does not hold it.
      {:ok, other} = Postgrex.start_link(session_config())
      Postgrex.query!(other, "SELECT pg_advisory_lock($1)", [classid * 4_294_967_296 + objid])
      certifi_release([name()])

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      GenServer.stop(other)
    end

    test "a run's job times out above the drift budget" do
      job = %Oban.Job{args: %{"package" => "certifi", "version" => "2.19.0"}}
      timeout = ReleaseFastPath.timeout(job)
      assert is_integer(timeout)
      assert timeout > Portal.Workers.ClosureDrift.budget_ms()
    end

    # Review F2: a newer release has its own job, which does the same work.
    test "a job whose release is no longer the newest stable one ends" do
      dependent = name()
      certifi_release([dependent])
      {:ok, registry} = Process.get(:hex_answer)

      registry =
        Enum.map(registry, fn
          %{name: "certifi"} = e ->
            %{e | versions: e.versions ++ ["2.20.0"], latest_version: "2.20.0"}

          e ->
            e
        end)

      Process.put(:hex_answer, {:ok, registry})

      assert {:ok, %{superseded: "2.20.0"}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert fast_path_builds() == []
    end

    # Re-review G8: a prerelease is no newer stable release.
    test "a newer prerelease leaves the job running" do
      dependent = name()
      certifi_release([dependent])
      put_certifi_versions(["2.18.0", "2.19.0", "2.20.0-rc.0"])

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert [%{args: %{"package" => ^dependent}}] = fast_path_builds()
    end

    # Re-review G7: with no stable release left on Hex (all retired, or the
    # package gone), there is nothing it was superseded by.
    test "a release with no stable release left ends, and says so" do
      certifi_release([name()])
      put_certifi_versions(["2.18.0", "2.19.0"], retired: ["2.18.0", "2.19.0"])

      log =
        info_log(fn ->
          assert {:ok, %{superseded: nil}} =
                   perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})
        end)

      assert log =~ "certifi 2.19.0: no stable release of certifi left on Hex"
      refute log =~ "superseded by"
      assert fast_path_builds() == []
    end

    # A retired offered release leaves an older one newest: the job ends, as
    # the offer and the judge ignore retired releases, and the log says so
    # rather than naming a newer release.
    test "a retired release ends, and the log names the newest stable one" do
      certifi_release([name()])
      put_certifi_versions(["2.18.0", "2.19.0"], retired: ["2.19.0"])

      log =
        info_log(fn ->
          assert {:ok, %{superseded: "2.18.0"}} =
                   perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})
        end)

      assert log =~ "certifi 2.19.0: no longer the newest stable release (2.18.0)"
      assert fast_path_builds() == []
    end

    test "uniqueness outlives the carry-over and the offer window" do
      period = ReleaseFastPath.__opts__()[:unique][:period]

      assert period >=
               (ReleaseFastPath.carry_over_hours() + ReleaseFastPath.window_hours()) * 3600
    end

    test "the budget is below the measured hourly throughput by default" do
      Application.put_env(:portal, ReleaseFastPath, enabled: true)
      assert ReleaseFastPath.budget() == 300
    end

    test "does nothing while the drift rebuilds are switched off" do
      # Two dependents: enough to be offered while drift is on.
      certifi_release([name(), name()])
      drift = Application.get_env(:portal, Portal.Workers.ClosureDrift, [])

      Application.put_env(
        :portal,
        Portal.Workers.ClosureDrift,
        Keyword.put(drift, :enabled, false)
      )

      on_exit(fn -> Application.put_env(:portal, Portal.Workers.ClosureDrift, drift) end)

      assert {:cancel, _} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert all_enqueued(worker: ToolchainBuild) == []

      assert ReleaseFastPath.offer([entry("certifi", ["2.18.0", "2.19.0"], @now)], now: @now) ==
               0
    end

    test "does nothing while switched off" do
      certifi_release([name()])
      Application.put_env(:portal, ReleaseFastPath, enabled: false)

      assert {:cancel, _} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert all_enqueued(worker: ToolchainBuild) == []
    end
  end
end
