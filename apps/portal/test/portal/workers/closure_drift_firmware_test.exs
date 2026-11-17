defmodule Portal.Workers.ClosureDriftFirmwareTest do
  # Not async: it swaps the worker's and the registry's application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query, only: [from: 2]
  import Portal.PrecompiledFixtures

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.Package
  alias Portal.Workers.{Build, ClosureDrift}

  @released ~U[2026-11-12 00:00:00Z]

  defmodule StubRegistry do
    def snapshot(_opts), do: Process.get(:hex_answer, {:ok, []})
  end

  setup do
    drift = Application.get_env(:portal, ClosureDrift, [])
    Application.put_env(:portal, :hex_registry_source, StubRegistry)

    on_exit(fn ->
      Application.put_env(:portal, ClosureDrift, drift)
      Application.delete_env(:portal, :hex_registry_source)
    end)

    :ok
  end

  defp entry(name, versions) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: @released,
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

  # `name` 0.3.0 and 0.4.0 on Hex, each `telemetry ~> 1.0`; telemetry 1.4.3
  # and nerves_system_rpi4 2.2.2 are out.
  defp world(names, telemetry \\ ["1.4.2", "1.4.3"]) do
    entries =
      [
        entry("telemetry", telemetry),
        entry("nerves_system_rpi4", ["2.2.1", "2.2.2"]),
        entry("nerves_system_x86_64", ["1.35.2"])
      ] ++ Enum.map(names, &entry(&1, ["0.3.0", "0.4.0"]))

    Process.put(:hex_answer, {:ok, entries})

    Process.put(
      {Portal.Test.FakeHexDeps, :releases},
      names
      |> Map.new(fn name ->
        {name,
         [
           release("0.3.0", [{"telemetry", "~> 1.0"}]),
           release("0.4.0", [{"telemetry", "~> 1.0"}])
         ]}
      end)
      |> Map.put("telemetry", Enum.map(telemetry, &release(&1, [])))
    )
  end

  defp lock(telemetry),
    do: %{"telemetry" => %{"version" => telemetry, "checksum" => "c-#{telemetry}"}}

  defp system(status, version), do: %{"status" => status, "system_version" => version}

  # A run of `name` `version`: rpi4 2.2.2 and x86_64 pass, bbb fails.
  defp run!(name, version, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "fw-drift-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    systems =
      Keyword.get(opts, :systems, %{
        "nerves_system_rpi4" => system("pass", "2.2.2"),
        "nerves_system_x86_64" => system("pass", "1.35.2"),
        "nerves_system_bbb" => system("fail", "2.31.2"),
        "host" => system("pass", nil)
      })

    result =
      %{
        "package" => %{"name" => name, "version" => version},
        "deps_lock" => lock(Keyword.get(opts, :telemetry, "1.4.2")),
        "finished_at" => Keyword.get(opts, :finished_at, "2026-11-10T00:00:00Z"),
        "systems" => systems
      }
      |> Map.merge(Keyword.get(opts, :result, %{}))

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: name,
        version: version,
        run_id: "#{name}-#{System.unique_integer([:positive])}",
        image_digest: "sha256:fw",
        files_dir: dir,
        log: "l"
      })

    run
  end

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # What `Portal.Precompiled.ElfFacts` would have read from the run's files.
  defp facts!(run, facts) do
    Repo.update_all(
      from(s in "catalog_system_results", where: s.run_id == type(^run.id, Ecto.UUID)),
      set: facts
    )
  end

  defp name, do: "fw_drift_#{System.unique_integer([:positive])}"

  defp firmware_jobs, do: all_enqueued(worker: Build)

  # What exhausting its attempts `days` ago leaves: a discarded job, no run.
  defp discard_builds!(days) do
    Repo.update_all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"),
      set: [state: "discarded", inserted_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )
  end

  test "queues a targets rebuild of the drifted passing targets, low priority, saying why" do
    name = name()
    world([name])
    run!(name, "0.4.0")

    assert {:ok, %{firmware: %{enqueued: 1, drifted: 1, targets: 2}}} = ClosureDrift.run()

    assert [job] = firmware_jobs()
    assert job.priority == 8
    assert job.queue == "builds"

    assert job.args == %{
             "package" => name,
             "version" => "0.4.0",
             "force" => true,
             "scope" => "targets",
             "systems" => ["nerves_system_rpi4", "nerves_system_x86_64"],
             "reason" => "closure_drift",
             "drift" => [%{"dep" => "telemetry", "from" => "1.4.2", "to" => "1.4.3"}]
           }

    # The scope the build will run: the latest run is of this version.
    assert %{systems_filter: ["nerves_system_rpi4", "nerves_system_x86_64"]} =
             Build.scope_args(name, "0.4.0", job.args)
  end

  test "an older release and a current lock are left alone" do
    [old, current] = [name(), name()]
    world([old, current])
    run!(old, "0.3.0")
    run!(current, "0.4.0", telemetry: "1.4.3")

    assert {:ok, %{firmware: %{enqueued: 0, drifted: 0}}} = ClosureDrift.run()
    assert firmware_jobs() == []
  end

  test "rebuilds a native build only used on its own release when its system moved" do
    name = name()
    world([name])

    run =
      run!(name, "0.4.0",
        telemetry: "1.4.3",
        systems: %{
          "nerves_system_rpi4" => system("pass", "2.2.1"),
          "nerves_system_x86_64" => system("pass", "1.35.2")
        }
      )

    facts!(run, native: true, portable: false)

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert [%{args: %{"systems" => ["nerves_system_rpi4"], "drift" => drift}}] = firmware_jobs()
    assert drift == [%{"dep" => "nerves_system_rpi4", "from" => "2.2.1", "to" => "2.2.2"}]
  end

  test "leaves beam-only targets to a host build, and rebuilds targets that never recorded a lock" do
    [covered, unlocked] = [name(), name()]
    world([covered, unlocked])

    covered_run =
      run!(covered, "0.4.0", result: %{"toolchain" => %{"elixir" => "1.20.3", "erlang" => "29"}})

    facts!(covered_run, native: false, portable: true)

    ingest_toolchain_build(covered, "0.4.0",
      toolchain: "1.20/29",
      elixir: "1.20.3",
      otp: "29",
      deps_lock: lock("1.4.3")
    )

    run!(unlocked, "0.4.0", result: %{"deps_lock" => nil}, finished_at: "2026-09-29T11:24:04Z")

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()

    assert [%{args: %{"package" => ^unlocked, "drift" => [%{"dep" => "*"}]}}] =
             firmware_jobs()
  end

  test "a run queues at most its cap, most downloaded package first" do
    [obscure, popular] = [name(), name()]
    world([obscure, popular])
    run!(obscure, "0.4.0")
    run!(popular, "0.4.0")
    downloads!(obscure, 10)
    downloads!(popular, 1_000_000)
    Application.put_env(:portal, ClosureDrift, enabled: true, firmware_max_per_run: 1)

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert [%{args: %{"package" => ^popular}}] = firmware_jobs()
  end

  # A retry of the job (`max_attempts: 2`), a manual run or a second run the
  # same day finds the first run's builds pending and would queue the next
  # ones: the cap counts the drift builds still waiting, and today's.
  test "the cap holds across a second run while the first run's builds wait" do
    [obscure, popular] = [name(), name()]
    world([obscure, popular])
    run!(obscure, "0.4.0")
    run!(popular, "0.4.0")
    downloads!(obscure, 10)
    downloads!(popular, 1_000_000)
    Application.put_env(:portal, ClosureDrift, enabled: true, firmware_max_per_run: 1)

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert {:ok, %{firmware: %{enqueued: 0}}} = ClosureDrift.run()
    assert [%{args: %{"package" => ^popular}}] = firmware_jobs()

    # Built and gone the same day, it still counts until the day is over.
    Repo.update_all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    assert {:ok, %{firmware: %{enqueued: 0}}} = ClosureDrift.run()

    # A build still waiting from an earlier day counts too.
    Repo.update_all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"),
      set: [state: "available", inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)]
    )

    assert {:ok, %{firmware: %{enqueued: 0}}} = ClosureDrift.run()

    # Built on an earlier day, it no longer does.
    Repo.update_all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"),
      set: [state: "completed"]
    )

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
  end

  # Routed to a remote builder, a rebuild's job finishes once its lease is
  # written and is pruned after 12 hours, while the lease may wait for days.
  test "a lease from an earlier day still waiting counts against the cap" do
    [obscure, popular] = [name(), name()]
    world([obscure, popular])
    run!(obscure, "0.4.0")
    run!(popular, "0.4.0")
    downloads!(obscure, 10)
    downloads!(popular, 1_000_000)
    Application.put_env(:portal, ClosureDrift, enabled: true, firmware_max_per_run: 1)

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()

    yesterday = NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :day)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"))
    Repo.update_all("firmware_drift_attempts", set: [inserted_at: yesterday])

    {:ok, _lease} =
      Portal.Builders.Leases.enqueue(
        %{
          package: popular,
          version: "0.4.0",
          image_name: "ghcr.io/x/ncc-worker",
          image_digest: "sha256:" <> String.duplicate("a", 64),
          args: %{"systems_filter" => ["nerves_system_rpi4"]},
          priority: 8
        },
        notify: false
      )

    Repo.update_all("builder_leases", set: [inserted_at: NaiveDateTime.add(yesterday, 60)])

    assert {:ok, %{firmware: %{enqueued: 0, earlier: 1}}} = ClosureDrift.run()
    assert firmware_jobs() == []
  end

  # A build that keeps failing (a worker error, a lease no builder finishes)
  # lands no run, so the run it would replace stays the latest and drifted:
  # each day would queue it again, and such builds could fill the cap.
  test "a rebuild that landed no run waits until its inputs change" do
    name = name()
    world([name])
    run!(name, "0.4.0")

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    discard_builds!(1)
    assert {:ok, %{firmware: %{enqueued: 0, failed: 1}}} = ClosureDrift.run()
    assert firmware_jobs() == []

    # A newer release of a dependency it would lock.
    world([name], ["1.4.2", "1.4.3", "1.4.4"])
    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert [%{args: %{"drift" => [%{"to" => "1.4.4"}]}}] = firmware_jobs()
    discard_builds!(1)
    assert {:ok, %{firmware: %{enqueued: 0, failed: 1}}} = ClosureDrift.run()

    # A worker whose judge changed.
    ingest_toolchain_build(name, "0.4.0", toolchain: "1.20/29", elixir: "1.20.3", otp: "29")
    Repo.update_all("catalog_toolchain_builds", set: [judge_revision: 1_000])
    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    discard_builds!(1)
    assert {:ok, %{firmware: %{enqueued: 0, failed: 1}}} = ClosureDrift.run()

    # Nothing changed for a week: a failure that was the host's is retried.
    Repo.update_all("firmware_drift_attempts",
      set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -8, :day)]
    )

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
  end

  # Nearly every latest run on production locks some dependency, or sits on
  # a system release, that is not the newest (a beam-only target on an older
  # release, a dependency held back by a requirement), so the runs read first
  # can all be current, and stay so after their rebuilds.
  test "reads past a page of current runs to the drifted ones below it" do
    [popular, obscure] = [name(), name()]
    world([popular, obscure])

    # Current: its lock is, and its beam-only rpi4 build is used on 2.2.2.
    current =
      run!(popular, "0.4.0",
        telemetry: "1.4.3",
        systems: %{"nerves_system_rpi4" => system("pass", "2.2.1")}
      )

    facts!(current, native: false, portable: true)
    run!(obscure, "0.4.0")
    downloads!(popular, 1_000_000)
    downloads!(obscure, 10)
    Application.put_env(:portal, ClosureDrift, enabled: true, firmware_scan_limit: 1)

    assert {:ok, %{firmware: %{candidates: 2, enqueued: 1}}} = ClosureDrift.run()
    assert [%{args: %{"package" => ^obscure}}] = firmware_jobs()
  end

  test "a run past its time budget judges and reads nothing more" do
    name = name()
    world([name])
    run!(name, "0.4.0")
    Application.put_env(:portal, ClosureDrift, enabled: true, budget_ms: 0)

    assert {:ok, %{firmware: %{drifted: 0, enqueued: 0}}} = ClosureDrift.run()
    assert firmware_jobs() == []
  end

  test "a package with a build on the way is not queued again" do
    name = name()
    world([name])
    run!(name, "0.4.0")

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert {:ok, %{firmware: %{enqueued: 0, pending: 1}}} = ClosureDrift.run()
    assert [_job] = firmware_jobs()
  end

  test "a carried target is judged by the run that built it" do
    name = name()
    world([name])
    run!(name, "0.4.0")

    # A targets run rebuilt rpi4 at the new lock and carried x86_64.
    run!(name, "0.4.0",
      telemetry: "1.4.3",
      finished_at: "2026-11-13T00:00:00Z",
      result: %{"scope" => "targets"},
      systems: %{"nerves_system_rpi4" => system("pass", "2.2.2"), "host" => system("pass", nil)}
    )

    assert {:ok, %{firmware: %{enqueued: 1}}} = ClosureDrift.run()
    assert [%{args: %{"systems" => ["nerves_system_x86_64"]}}] = firmware_jobs()
  end

  test "a dry run queues nothing; switched off, the firmware phase does not run" do
    name = name()
    world([name])
    run!(name, "0.4.0")

    assert {:ok, %{firmware: %{drifted: 1, enqueued: 0, targets: 2}}} =
             ClosureDrift.run(dry_run: true)

    Application.put_env(:portal, ClosureDrift, enabled: true, firmware: false)
    assert {:ok, summary} = ClosureDrift.run()
    refute Map.has_key?(summary, :firmware)
    assert firmware_jobs() == []
  end

  test "the build a rebuild replaces keeps serving its lock beside the new one" do
    keyed = fn run_id, finished_at, telemetry ->
      Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"run_id" => run_id, "finished_at" => finished_at})
      |> Map.put("deps_lock", lock(telemetry))
      |> Map.put("package_checksum", "outer")
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])
    end

    ingest_with_artifact(keyed.("before", "2026-11-10T00:00:00Z", "1.4.2"))

    ingest_with_artifact(
      keyed.("after", "2026-11-13T00:00:00Z", "1.4.3")
      |> Map.put("scope", "targets")
      |> Map.update!("systems", &Map.take(&1, ["nerves_system_rpi4", "host"]))
    )

    %{"versions" => %{"1.4.1" => %{"builds" => builds}}} =
      Catalog.precompiled_manifest_v2("jason")

    assert builds
           |> Enum.filter(&(&1["target"] == "nerves_system_rpi4"))
           |> Enum.map(& &1["build"]["deps"])
           |> Enum.sort_by(&get_in(&1, ["telemetry", "version"])) ==
             [lock("1.4.2"), lock("1.4.3")]
  end
end
