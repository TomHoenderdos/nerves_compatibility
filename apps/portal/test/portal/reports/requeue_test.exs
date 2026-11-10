defmodule Portal.Reports.RequeueTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query, only: [from: 2]
  import Portal.Test.ReportFixtures

  alias Portal.Catalog.{Package, Run, SystemResult}
  alias Portal.Reports.Requeue
  alias Portal.Repo
  alias Portal.Workers.{Build, ReportRequeue, ToolchainBuild}

  setup do
    previous = Application.get_env(:portal, Portal.Reports.Quotas)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, Portal.Reports.Quotas, previous),
        else: Application.delete_env(:portal, Portal.Reports.Quotas)
    end)

    hex(%{"jason" => ["1.4.4", "1.4.5"], "telemetry" => ["1.3.0"]})
    # System builds go through `Routing.build_job/2`; keep them on the local
    # `Build` worker whatever builders the test database knows.
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})
    :ok
  end

  defp hex(versions) do
    Process.put(
      {Portal.Test.FakeHexDeps, :releases},
      Map.new(versions, fn {name, vs} ->
        {name, Enum.map(vs, &%{version: &1, retired?: false, deps: [], outer_checksum: nil})}
      end)
    )
  end

  defp package!(name) do
    Ash.create!(Package, %{name: name, latest_version: "1.0.0"},
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp run!(package, version, results) do
    run =
      Ash.create!(
        Run,
        %{
          run_id: "rid-#{System.unique_integer([:positive])}",
          package_id: package.id,
          version_tested: version,
          image_digest: "sha256:" <> String.duplicate("1", 64),
          overall_status: :pass
        },
        action: :create,
        domain: Portal.Catalog
      )

    for {system, system_version, status} <- results do
      Ash.create!(
        SystemResult,
        %{run_id: run.id, system_pkg: system, system_version: system_version, status: status},
        action: :create,
        domain: Portal.Catalog
      )
    end

    run
  end

  # A miss for `name` `version` on rpi4 1.31.0, from `reporter`.
  defp miss!(name, version, opts \\ []) do
    code = Keyword.get(opts, :code, "not_built_version")
    overrides = Keyword.get(opts, :body, %{})

    record!(
      Map.merge(
        %{
          "lines" => [line(name, version, "miss", code, [version])],
          "lock" => [lock(name, version)],
          "target" => "t#{System.unique_integer([:positive])}"
        },
        overrides
      ),
      reporter_key: Keyword.get(opts, :reporter, "reporter-a")
    )
  end

  defp decision(report_id) do
    Repo.one(
      from(l in "precompiled_report_lines",
        where: l.report_id == type(^report_id, Ecto.UUID),
        select: l.requeue
      )
    )
  end

  defp requeue(report_id), do: Requeue.run_report(report_id, today: ~D[2026-11-10])

  # A recent run that recorded rpi4 1.31.0 for some package: the image builds it.
  defp image_builds_rpi4!,
    do:
      run!(package!("other_#{System.unique_integer([:positive])}"), "1.0.0", [
        {"nerves_system_rpi4", "1.31.0", :pass}
      ])

  test "an unknown package is skipped and nothing is asked of Hex" do
    Process.delete({Portal.Test.FakeHexDeps, :releases})
    id = miss!("never_seen", "1.0.0")
    assert :ok = requeue(id)
    assert decision(id) == "skipped:unknown_package"
    refute_enqueued(worker: Build)
  end

  test "a known package whose version Hex does not list is skipped" do
    image_builds_rpi4!()
    jason = package!("jason")
    run!(jason, "1.4.4", [{"nerves_system_rpi4", "1.31.0", :pass}])
    id = miss!("jason", "9.9.9")
    assert :ok = requeue(id)
    assert decision(id) == "skipped:not_on_hex"
  end

  test "a system version the image never built is unbuildable" do
    jason = package!("jason")
    run!(jason, "1.4.4", [{"nerves_system_rpi4", "1.31.0", :pass}])
    id = miss!("jason", "1.4.5", body: %{"system_version" => "1.32.0"})
    assert :ok = requeue(id)
    assert decision(id) == "skipped:unbuildable"
    refute_enqueued(worker: Build)
  end

  test "a version with no run is queued as a full build, tagged with the report" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])
    id = miss!("jason", "1.4.5")
    assert :ok = requeue(id)
    assert decision(id) == "queued"

    assert_enqueued(
      worker: Build,
      args: %{"package" => "jason", "version" => "1.4.5"},
      meta: %{"report_id" => id},
      priority: 9
    )
  end

  test "the check is keyed on the tuple: another system's result does not block rpi4" do
    image_builds_rpi4!()
    jason = package!("jason")
    run!(jason, "1.4.5", [{"nerves_system_bbb", "2.0.0", :pass}, {"host", nil, :pass}])
    id = miss!("jason", "1.4.5", code: "not_built_target")
    assert :ok = requeue(id)
    assert decision(id) == "queued"

    assert_enqueued(
      worker: Build,
      args: %{
        "package" => "jason",
        "version" => "1.4.5",
        "force" => true,
        "scope" => "targets",
        "systems" => ["nerves_system_rpi4"]
      }
    )
  end

  test "an infrastructure-failed tuple is requeued, a judged one is not" do
    image_builds_rpi4!()
    jason = package!("jason")
    run!(jason, "1.4.5", [{"nerves_system_rpi4", "1.31.0", :error}])
    errored = miss!("jason", "1.4.5", code: "not_built_target")
    assert :ok = requeue(errored)
    assert decision(errored) == "queued"

    telemetry = package!("telemetry")
    run!(telemetry, "1.3.0", [{"nerves_system_rpi4", "1.31.0", :fail}])
    judged = miss!("telemetry", "1.3.0", code: "not_built_target")
    assert :ok = requeue(judged)
    assert decision(judged) == "skipped:judged"
  end

  test "a tuple already queued is not queued again" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])
    first = miss!("jason", "1.4.5")
    second = miss!("jason", "1.4.5", reporter: "reporter-b")
    assert :ok = requeue(first)
    assert :ok = requeue(second)
    assert decision(first) == "queued"
    assert decision(second) == "skipped:queued"
  end

  test "the per-package cap holds" do
    Application.put_env(:portal, Portal.Reports.Quotas, package: 1)
    image_builds_rpi4!()
    package!("jason") |> run!("1.0.0", [])
    a = miss!("jason", "1.4.4")
    b = miss!("jason", "1.4.5", reporter: "reporter-b")
    :ok = requeue(a)
    :ok = requeue(b)
    assert {decision(a), decision(b)} == {"queued", "skipped:cap"}
  end

  test "the per-reporter cap holds" do
    Application.put_env(:portal, Portal.Reports.Quotas, reporter: 1)
    image_builds_rpi4!()
    package!("jason") |> run!("1.0.0", [])
    package!("telemetry") |> run!("1.0.0", [])
    a = miss!("jason", "1.4.5")
    b = miss!("telemetry", "1.3.0")
    :ok = requeue(a)
    :ok = requeue(b)
    assert {decision(a), decision(b)} == {"queued", "skipped:cap"}
  end

  test "the global cap holds across reporters, and a refusal uses no other budget" do
    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    image_builds_rpi4!()
    package!("jason") |> run!("1.0.0", [])
    package!("telemetry") |> run!("1.0.0", [])
    a = miss!("jason", "1.4.5")
    b = miss!("telemetry", "1.3.0", reporter: "reporter-b")
    :ok = requeue(a)
    :ok = requeue(b)
    assert {decision(a), decision(b)} == {"queued", "skipped:cap"}

    used =
      Repo.one(
        from(q in "precompiled_report_quotas",
          where: q.key == "package:telemetry",
          select: q.used
        )
      )

    assert used in [nil, 0]
  end

  test "a host report queues the toolchain build of its Elixir minor and OTP" do
    package!("jason") |> run!("1.0.0", [])

    id =
      miss!("jason", "1.4.5",
        body: %{
          "target" => "host",
          "system" => nil,
          "system_version" => nil,
          "elixir" => "1.19.5",
          "otp" => 28
        }
      )

    assert :ok = requeue(id)
    assert decision(id) == "queued"

    assert_enqueued(
      worker: ToolchainBuild,
      args: %{
        "package" => "jason",
        "version" => "1.4.5",
        "toolchain" => "1.19/28",
        "variant" => "with",
        "config_variant" => "default"
      },
      priority: 9
    )
  end

  test "a host report for a toolchain nobody builds on is unbuildable" do
    package!("jason") |> run!("1.0.0", [])

    id =
      miss!("jason", "1.4.5",
        body: %{
          "target" => "host",
          "system" => nil,
          "system_version" => nil,
          "elixir" => "1.15.8",
          "otp" => 26
        }
      )

    assert :ok = requeue(id)
    assert decision(id) == "skipped:unbuildable"
  end

  test "a judged toolchain build is not requeued" do
    jason = package!("jason")
    run!(jason, "1.0.0", [])

    Ash.create!(
      Portal.Catalog.ToolchainBuild,
      %{
        package_id: jason.id,
        version: "1.4.5",
        toolchain: "1.19/28",
        builder_version: Portal.Toolchains.builder_version(),
        status: :skipped
      },
      action: :create,
      domain: Portal.Catalog
    )

    id =
      miss!("jason", "1.4.5",
        body: %{
          "target" => "host",
          "system" => nil,
          "system_version" => nil,
          "elixir" => "1.19.5",
          "otp" => 28
        }
      )

    assert :ok = requeue(id)
    assert decision(id) == "skipped:judged"
  end

  test "Hex being unavailable decides nothing and asks to retry" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.0.0", [])
    id = miss!("jason", "1.4.5")

    defmodule DownHex do
      def releases(_name, _opts), do: {:error, :hex_registry_unavailable}
    end

    assert {:error, :hex_unavailable} = Requeue.run_report(id, hex_deps: DownHex)
    assert decision(id) == nil
  end

  test "only not-built misses are decided" do
    id = record!(%{"lines" => [line("jason", "1.4.5", "miss", "toolchain_otp", ["28", "29"])]})
    assert :ok = requeue(id)
    assert decision(id) == nil
  end

  test "a new report with a not-built miss enqueues one requeue job; a duplicate none" do
    {:ok, payload} =
      Portal.Reports.Payload.validate(
        body(%{"lines" => [line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"])]})
      )

    {:created, id} = Portal.Reports.record(payload, "k")
    assert_enqueued(worker: ReportRequeue, args: %{"report_id" => id})

    :duplicate = Portal.Reports.record(payload, "k")
    assert length(all_enqueued(worker: ReportRequeue)) == 1

    {:ok, other} =
      Portal.Reports.Payload.validate(
        body(%{"lines" => [line("jason", "1.4.5", "miss", "toolchain_otp", ["28", "29"])]})
      )

    {:created, _} = Portal.Reports.record(other, "k")
    assert length(all_enqueued(worker: ReportRequeue)) == 1
  end

  defp used(key, day \\ ~D[2026-11-10]) do
    Repo.one(
      from(q in "precompiled_report_quotas",
        where: q.key == ^key and q.day == ^day,
        select: q.used
      )
    )
  end

  test "the caps are spent on the given day" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])
    id = miss!("jason", "1.4.5")
    assert :ok = Requeue.run_report(id, today: ~D[2031-01-02])
    assert used("package:jason", ~D[2031-01-02]) == 1
    assert used("package:jason", Date.utc_today()) in [nil, 0]
  end

  test "without a day, the caps are spent on today's UTC date" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])
    id = miss!("jason", "1.4.5")
    assert :ok = Requeue.run_report(id)
    assert decision(id) == "queued"
    assert used("global", Date.utc_today()) == 1
    assert used("package:jason", Date.utc_today()) == 1
    assert used("reporter:reporter-a", Date.utc_today()) == 1
  end

  test "a report without a reporter key spends the shared reporter:none budget" do
    Application.put_env(:portal, Portal.Reports.Quotas, reporter: 1)
    image_builds_rpi4!()
    package!("jason") |> run!("1.0.0", [])
    package!("telemetry") |> run!("1.0.0", [])
    a = miss!("jason", "1.4.5", reporter: nil)
    b = miss!("telemetry", "1.3.0", reporter: nil)
    :ok = requeue(a)
    :ok = requeue(b)
    assert {decision(a), decision(b)} == {"queued", "skipped:cap"}
    assert used("reporter:none") == 1
  end

  test "a job Oban reports as a unique conflict is skipped:queued and spends nothing" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])

    # A build of the same version that finished inside `Build`'s unique
    # window: not waiting, so only Oban's own unique check sees it.
    done = Oban.insert!(Build.new(%{package: "jason", version: "1.4.5"}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^done.id),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    id = miss!("jason", "1.4.5")
    assert :ok = requeue(id)
    assert decision(id) == "skipped:queued"
    assert used("global") in [nil, 0]
    assert used("package:jason") in [nil, 0]
    assert used("reporter:reporter-a") in [nil, 0]
  end

  test "a job that cannot be inserted is skipped:error, logged, and spends nothing" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.4", [])
    id = miss!("jason", "1.4.5")
    failing = fn _changeset -> {:error, :insert_refused} end

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert :ok = Requeue.run_report(id, today: ~D[2026-11-10], insert: failing)
      end)

    assert decision(id) == "skipped:error"
    assert log =~ "insert_refused"
    assert used("global") in [nil, 0]
    assert used("package:jason") in [nil, 0]
    refute_enqueued(worker: Build)
  end

  test "a system version older than the newest one built is superseded, not rebuilt" do
    jason = package!("jason")

    run!(jason, "1.4.5", [
      {"nerves_system_rpi4", "2.1.0", :pass},
      {"nerves_system_rpi4", "2.0.0", :error}
    ])

    id = miss!("jason", "1.4.5", code: "not_built_target", body: %{"system_version" => "2.0.0"})
    assert :ok = requeue(id)
    assert decision(id) == "skipped:superseded"
    refute_enqueued(worker: Build)
  end

  test "the newest system version built stays buildable" do
    other = package!("other")

    run!(other, "1.0.0", [
      {"nerves_system_rpi4", "1.31.0", :pass},
      {"nerves_system_rpi4", "1.9.0", :pass}
    ])

    package!("jason") |> run!("1.4.4", [])
    id = miss!("jason", "1.4.5")
    assert :ok = requeue(id)
    assert decision(id) == "queued"
  end

  test "a waiting build of other targets does not cover this system" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.5", [])

    Oban.insert!(
      Build.new(%{
        package: "jason",
        version: "1.4.5",
        force: true,
        scope: "targets",
        systems: ["nerves_system_bbb"]
      })
    )

    id = miss!("jason", "1.4.5", code: "not_built_target")
    assert :ok = requeue(id)
    assert decision(id) == "queued"
  end

  test "a waiting build of this target, or a full build, covers it" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.5", [])
    package!("telemetry") |> run!("1.0.0", [])

    Oban.insert!(
      Build.new(%{
        package: "jason",
        version: "1.4.5",
        force: true,
        scope: "targets",
        systems: ["nerves_system_rpi4"]
      })
    )

    Oban.insert!(Build.new(%{package: "telemetry", version: "1.3.0"}))

    targeted = miss!("jason", "1.4.5", code: "not_built_target")
    full = miss!("telemetry", "1.3.0")
    assert :ok = requeue(targeted)
    assert :ok = requeue(full)
    assert decision(targeted) == "skipped:queued"
    assert decision(full) == "skipped:queued"
  end

  test "a remote lease for other targets does not cover this system" do
    image_builds_rpi4!()
    package!("jason") |> run!("1.4.5", [])

    Repo.insert_all("builder_leases", [
      %{
        id: Ecto.UUID.bingenerate(),
        package: "jason",
        version: "1.4.5",
        image_name: "img",
        image_digest: "sha256:" <> String.duplicate("2", 64),
        args: %{
          "package" => "jason",
          "version" => "1.4.5",
          "scope" => "targets",
          "systems" => ["nerves_system_bbb"]
        },
        state: "queued",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    id = miss!("jason", "1.4.5", code: "not_built_target")
    assert :ok = requeue(id)
    assert decision(id) == "queued"
  end

  test "a package whose only runs are revoked is unknown" do
    jason = package!("jason")
    run = run!(jason, "1.4.4", [{"nerves_system_rpi4", "1.31.0", :pass}])
    image_builds_rpi4!()

    Repo.update_all(from(r in "catalog_runs", where: r.id == type(^run.id, Ecto.UUID)),
      set: [revoked_at: DateTime.utc_now()]
    )

    id = miss!("jason", "1.4.5")
    assert :ok = requeue(id)
    assert decision(id) == "skipped:unknown_package"
  end

  defmodule CountingHex do
    def releases(name, opts) do
      send(self(), {:hex_asked, name})
      Portal.Test.FakeHexDeps.releases(name, opts)
    end
  end

  test "Hex is asked only for buildable lines, once per package, at most 20 packages a run" do
    image_builds_rpi4!()
    names = for i <- 1..22, do: "pkg_#{String.pad_leading(Integer.to_string(i), 2, "0")}"
    for name <- names, do: package!(name) |> run!("1.0.0", [])
    package!("jason") |> run!("1.0.0", [])
    hex(Map.new(names, &{&1, ["1.0.1"]}))

    lines = for name <- names, do: line(name, "1.0.1", "miss", "not_built_version", ["1.0.1"])
    twice = line("pkg_01", "1.0.1", "miss", "not_built_target", [])

    id =
      record!(%{
        "lines" => lines ++ [twice],
        "lock" => Enum.map(names, &lock(&1, "1.0.1")),
        "target" => "t#{System.unique_integer([:positive])}"
      })

    # An unbuildable line costs no lookup.
    stale = miss!("jason", "1.4.5", body: %{"system_version" => "0.0.1"})
    assert :ok = Requeue.run_report(stale, today: ~D[2026-11-10], hex_deps: CountingHex)
    assert decision(stale) == "skipped:unbuildable"
    refute_received {:hex_asked, _}

    assert :ok = Requeue.run_report(id, today: ~D[2026-11-10], hex_deps: CountingHex)

    asked = collect_asked([])
    assert length(asked) == 20
    assert asked == Enum.uniq(asked)

    decisions =
      Repo.all(
        from(l in "precompiled_report_lines",
          where: l.report_id == type(^id, Ecto.UUID),
          select: {l.package, l.requeue}
        )
      )

    undecided = for {p, nil} <- decisions, do: p
    assert Enum.sort(undecided) == ["pkg_21", "pkg_22"]
    refute Enum.any?(decisions, fn {p, _} -> p in ["pkg_21", "pkg_22"] and p in asked end)
  end

  defp collect_asked(acc) do
    receive do
      {:hex_asked, name} -> collect_asked([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
