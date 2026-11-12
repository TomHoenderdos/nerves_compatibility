defmodule Portal.Reports.RequeueSweepTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query, only: [from: 2]
  import Portal.Test.ReportFixtures

  alias Portal.Catalog.{Package, Run, SystemResult}
  alias Portal.Reports.Requeue
  alias Portal.Repo
  alias Portal.Workers.{Build, ReportRequeue, ReportRequeueSweep}

  setup do
    previous = Application.get_env(:portal, Portal.Reports.Quotas)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, Portal.Reports.Quotas, previous),
        else: Application.delete_env(:portal, Portal.Reports.Quotas)
    end)

    Process.put(
      {Portal.Test.FakeHexDeps, :releases},
      Map.new(
        ~w(alpha beta),
        &{&1, [%{version: "1.0.0", retired?: false, deps: [], outer_checksum: nil}]}
      )
    )

    # System builds go through `Routing.build_job/2`; keep them on the local
    # `Build` worker whatever builders the test database knows.
    {:ok, _} = Portal.Settings.save(%{remote_mode: :off})

    for name <- ~w(alpha beta) do
      p =
        Ash.create!(Package, %{name: name, latest_version: "1.0.0"},
          action: :create,
          domain: Portal.Catalog
        )

      run =
        Ash.create!(
          Run,
          %{
            run_id: "r-#{name}",
            package_id: p.id,
            version_tested: "0.9.0",
            image_digest: "d",
            overall_status: :pass
          },
          action: :create,
          domain: Portal.Catalog
        )

      Ash.create!(
        SystemResult,
        %{
          run_id: run.id,
          system_pkg: "nerves_system_rpi4",
          system_version: "1.31.0",
          status: :pass
        },
        action: :create,
        domain: Portal.Catalog
      )
    end

    :ok
  end

  defp miss!(package, reporter) do
    record!(
      %{
        "lines" => [line(package, "1.0.0", "miss", "not_built_version", ["1.0.0"])],
        "target" => "t#{System.unique_integer([:positive])}"
      },
      reporter_key: reporter
    )
  end

  defp capped!(package, reporter) do
    id = miss!(package, reporter)
    set_line!(id, requeue: "skipped:cap")
    id
  end

  defp set_line!(id, set),
    do:
      Repo.update_all(
        from(l in "precompiled_report_lines", where: l.report_id == type(^id, Ecto.UUID)),
        set: set
      )

  defp set_report!(id, set),
    do:
      Repo.update_all(
        from(r in "precompiled_reports", where: r.id == type(^id, Ecto.UUID)),
        set: set
      )

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  # The report's own requeue job, as `record/3` enqueued it, spent.
  defp discard_report_job!(id) do
    {1, _} =
      Repo.update_all(
        from(j in "oban_jobs",
          where:
            j.worker == "Portal.Workers.ReportRequeue" and
              fragment("?->>'report_id'", j.args) == ^id
        ),
        set: [state: "discarded"]
      )
  end

  defp decision(id),
    do:
      Repo.one(
        from(l in "precompiled_report_lines",
          where: l.report_id == type(^id, Ecto.UUID),
          select: l.requeue
        )
      )

  test "the sweep retries capped lines, the most-reported tuple first" do
    # alpha first seen earlier, by one reporter; beta later, by three.
    alpha = capped!("alpha", "r1")
    beta = for r <- ~w(r2 r3 r4), do: capped!("beta", r)

    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    assert :ok = Requeue.sweep(today: ~D[2026-11-11])

    assert decision(hd(beta)) == "queued"
    assert decision(alpha) == "skipped:cap"
    assert Enum.map(tl(beta), &decision/1) == ["skipped:queued", "skipped:queued"]
  end

  test "between equally reported tuples, the one first seen earliest goes first" do
    beta = capped!("beta", "r1")
    alpha = capped!("alpha", "r2")
    set_report!(beta, received_at: ago(7_200))
    set_report!(alpha, received_at: ago(3_600))

    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    assert :ok = Requeue.sweep(today: ~D[2026-11-11])

    assert decision(beta) == "queued"
    assert decision(alpha) == "skipped:cap"
  end

  test "a report whose reporter key was cleared counts as one more reporter" do
    # alpha: one keyed reporter and one cleared; beta: one reporter, earlier.
    beta = capped!("beta", "r1")
    set_report!(beta, received_at: ago(7_200))
    alpha = [capped!("alpha", "r2"), capped!("alpha", "r3")]
    set_report!(List.last(alpha), reporter_key: nil)

    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    assert :ok = Requeue.sweep(today: ~D[2026-11-11])

    assert decision(hd(alpha)) == "queued"
    assert decision(beta) == "skipped:cap"
  end

  test "lines older than seven days are not retried" do
    old = capped!("alpha", "r1")
    set_report!(old, received_at: ago(8 * 86_400))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(old) == "skipped:cap"
    refute_enqueued(worker: Build)
  end

  test "lines decided otherwise are left alone" do
    id = capped!("alpha", "r1")
    set_line!(id, requeue: "skipped:judged")

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == "skipped:judged"
    refute_enqueued(worker: Build)
  end

  test "an undecided line is retried once its report's own job is spent and an hour has passed" do
    id = miss!("alpha", "r1")
    discard_report_job!(id)
    set_report!(id, received_at: ago(3_700))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == "queued"
    assert_enqueued(worker: Build, args: %{package: "alpha", version: "1.0.0"})
  end

  test "an undecided line of a report from the last hour is left to its own job" do
    id = miss!("alpha", "r1")
    discard_report_job!(id)
    set_report!(id, received_at: ago(1_800))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == nil
  end

  test "an undecided line whose report's own job is still waiting is left to that job" do
    id = miss!("alpha", "r1")
    assert_enqueued(worker: ReportRequeue, args: %{report_id: id})
    set_report!(id, received_at: ago(3_700))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == nil
    refute_enqueued(worker: Build)
  end

  test "an undecided line older than seven days is not retried" do
    id = miss!("alpha", "r1")
    discard_report_job!(id)
    set_report!(id, received_at: ago(8 * 86_400))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == nil
  end

  test "undecided and capped lines share one order" do
    alpha = capped!("alpha", "r1")
    set_report!(alpha, received_at: ago(7_200))

    beta =
      for r <- ~w(r2 r3) do
        id = miss!("beta", r)
        discard_report_job!(id)
        set_report!(id, received_at: ago(3_700))
        id
      end

    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    assert :ok = Requeue.sweep(today: ~D[2026-11-11])

    assert Enum.map(beta, &decision/1) == ["queued", "skipped:queued"]
    assert decision(alpha) == "skipped:cap"
  end

  test "if Hex cannot answer, nothing is decided" do
    id = capped!("alpha", "r1")

    assert {:error, :hex_unavailable} =
             Requeue.sweep(today: ~D[2026-11-11], hex_deps: __MODULE__.DownHex)

    assert decision(id) == "skipped:cap"
  end

  test "the sweep decides at most its limit of lines a run, in its order" do
    a1 = capped!("alpha", "r1")
    a2 = capped!("alpha", "r2")
    b = capped!("beta", "r3")

    assert :ok = Requeue.sweep(today: ~D[2026-11-11], limit: 2)
    assert {decision(a1), decision(a2)} == {"queued", "skipped:queued"}
    assert decision(b) == "skipped:cap"
  end

  test "the sweep retries a capped closure_mismatch line against a stale build" do
    alpha = Repo.one!(from(p in Package, where: p.name == "alpha"))

    Process.put(
      {Portal.Test.FakeHexDeps, :releases},
      %{
        "alpha" => [
          %{
            version: "1.0.0",
            retired?: false,
            deps: [%{package: "elixir_make", requirement: "~> 0.10"}],
            outer_checksum: nil
          }
        ]
      }
    )

    # The setup's 0.9.0 run finished first: 1.0.0 is the latest tested.
    Repo.update_all(from(r in Run, where: r.package_id == ^alpha.id),
      set: [finished_at: DateTime.add(DateTime.utc_now(), -86_400)]
    )

    run =
      Ash.create!(
        Run,
        %{
          run_id: "r-alpha-1.0.0",
          package_id: alpha.id,
          version_tested: "1.0.0",
          image_digest: "d",
          overall_status: :pass,
          deps_lock: %{"elixir_make" => %{"version" => "0.10.0", "checksum" => "c"}},
          finished_at: DateTime.utc_now()
        },
        action: :create,
        domain: Portal.Catalog
      )

    Ash.create!(
      SystemResult,
      %{
        run_id: run.id,
        system_pkg: "nerves_system_rpi4",
        system_version: "1.31.0",
        status: :pass
      },
      action: :create,
      domain: Portal.Catalog
    )

    id =
      record!(
        %{
          "lines" => [
            line("alpha", "1.0.0", "miss", "closure_mismatch", ["elixir_make", "0.10.0", "0.10.1"])
          ],
          "target" => "t#{System.unique_integer([:positive])}"
        },
        reporter_key: "r1"
      )

    set_line!(id, requeue: "skipped:cap")

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(id) == "queued"

    assert_enqueued(
      worker: Build,
      args: %{
        package: "alpha",
        version: "1.0.0",
        force: true,
        scope: "targets",
        systems: ["nerves_system_rpi4"]
      },
      meta: %{report_id: id}
    )
  end

  test "the sweep reads 500 lines a run by default" do
    assert Requeue.sweep_limit() == 500
  end

  test "the sweep stops once the global cap refuses" do
    Application.put_env(:portal, Portal.Reports.Quotas, global: 1)
    spend!("global", ~D[2026-11-11])
    a1 = capped!("alpha", "r1")
    a2 = capped!("alpha", "r2")
    b = miss!("beta", "r3")
    discard_report_job!(b)
    set_report!(b, received_at: ago(3_700))

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert decision(a1) == "skipped:cap"
    assert decision(a2) == "skipped:cap"
    # Never reached: still undecided, for the next day's sweep.
    assert decision(b) == nil
  end

  test "a package cap does not stop the sweep" do
    Application.put_env(:portal, Portal.Reports.Quotas, package: 1)
    spend!("package:alpha", ~D[2026-11-11])
    a1 = capped!("alpha", "r1")
    a2 = capped!("alpha", "r2")
    b = capped!("beta", "r3")

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])
    assert {decision(a1), decision(a2)} == {"skipped:cap", "skipped:cap"}
    assert decision(b) == "queued"
  end

  defp spend!(key, day) do
    {:ok, :ok} = Repo.transaction(fn -> Portal.Reports.Quotas.reserve([{key, 1}], day) end)
  end

  test "the sweep prunes counters older than a week" do
    Repo.query!(
      "INSERT INTO precompiled_report_quotas (key, day, used) VALUES ('global', '2026-11-01', 3)"
    )

    Repo.query!(
      "INSERT INTO precompiled_report_quotas (key, day, used) VALUES ('global', '2026-11-04', 3)"
    )

    assert :ok = Requeue.sweep(today: ~D[2026-11-11])

    assert Repo.all(from(q in "precompiled_report_quotas", select: q.day)) == [~D[2026-11-04]]
  end

  test "the worker runs the sweep" do
    id = capped!("alpha", "r1")
    assert :ok = perform_job(ReportRequeueSweep, %{})
    assert decision(id) == "queued"
  end

  defmodule DownHex do
    def releases(_name, _opts), do: {:error, :timeout}
  end
end
