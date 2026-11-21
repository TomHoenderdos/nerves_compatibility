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

    defp flush_registry_reads do
      receive do
        :asked_registry -> flush_registry_reads()
      after
        0 -> :ok
      end
    end

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
    test "only one job runs at a time: another holding the lock snoozes it a minute" do
      certifi_release([name()])
      # Linked: should the test fail, the session closes with it and so lets
      # its lock go.
      {:ok, other} = Postgrex.start_link(session_config())

      Postgrex.query!(other, "SELECT pg_advisory_lock($1)", [ReleaseFastPath.lock_key()])
      flush_registry_reads()

      assert {:snooze, 60} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert fast_path_builds() == []
      refute_received :asked_registry

      Postgrex.query!(other, "SELECT pg_advisory_unlock($1)", [ReleaseFastPath.lock_key()])

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      # The run let the lock go: the other session takes it at once.
      assert %{rows: [[true]]} =
               Postgrex.query!(other, "SELECT pg_try_advisory_lock($1)", [
                 ReleaseFastPath.lock_key()
               ])

      GenServer.stop(other)
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
