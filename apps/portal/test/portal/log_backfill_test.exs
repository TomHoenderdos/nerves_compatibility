defmodule Portal.LogBackfillTest do
  use Portal.DataCase, async: false

  import Ecto.Query

  alias Portal.Catalog.{Package, Run, SystemLog, SystemResult}
  alias Portal.LogBackfill
  alias Portal.Repo

  # Rows are built directly rather than through `Portal.Catalog.Ingestion` for
  # the same reason `Portal.Workers.LogRetentionTest` does it: every rule here
  # is about the *relationship* between runs -- which one is the latest, which
  # failure has a log -- and ingest offers no handle on either.

  defp package(name) do
    Ash.create!(Package, %{name: name, latest_version: "1.0.0"},
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp run(package, opts \\ []) do
    Ash.create!(
      Run,
      %{
        run_id: "rid-#{System.unique_integer([:positive])}",
        package_id: package.id,
        version_tested: Keyword.get(opts, :version, "1.0.0"),
        image_digest: "sha256:deadbeef",
        overall_status: Keyword.get(opts, :status, :fail),
        finished_at: Keyword.get(opts, :finished_at, DateTime.utc_now())
      },
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp system_result(run, status) do
    Ash.create!(
      SystemResult,
      %{
        run_id: run.id,
        system_pkg: "nerves_system_#{System.unique_integer([:positive])}",
        status: status
      },
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp log(system_result, body \\ "boom") do
    Ash.create!(
      SystemLog,
      %{body: body, byte_size: byte_size(body), system_result_id: system_result.id},
      action: :create,
      domain: Portal.Catalog
    )
  end

  defp build_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Portal.Workers.Build"))
  end

  describe "candidates/0" do
    test "a failure in the latest run with no log is a candidate" do
      p = package("unlogged")
      p |> run() |> system_result(:fail)

      assert LogBackfill.candidates() == [{"unlogged", "1.0.0"}]
    end

    test "a failure that already has a log is not" do
      p = package("logged")
      p |> run() |> system_result(:fail) |> log()

      assert LogBackfill.candidates() == []
    end

    test "a passing result is not" do
      p = package("green")
      p |> run(status: :pass) |> system_result(:pass)

      assert LogBackfill.candidates() == []
    end

    # Rebuilding this would pay a six-minute firmware build for a log that
    # `Portal.Workers.LogRetention`'s first rule deletes the same night, and
    # that no page could reach in the meantime.
    test "an unlogged failure in a superseded run is not" do
      p = package("superseded")

      p
      |> run(finished_at: ~U[2026-01-01 00:00:00Z])
      |> system_result(:fail)

      p
      |> run(finished_at: ~U[2026-02-01 00:00:00Z], status: :pass)
      |> system_result(:pass)

      assert LogBackfill.candidates() == []
    end

    test "one package with several unlogged failures is one candidate" do
      p = package("many")
      r = run(p)
      system_result(r, :fail)
      system_result(r, :fail)

      assert LogBackfill.candidates() == [{"many", "1.0.0"}]
    end
  end

  describe "run/1" do
    test "enqueues a forced, lowest-priority build with no image digest" do
      p = package("rebuildme")
      p |> run() |> system_result(:fail)

      assert {:ok, %{candidates: 1, enqueued: 1}} = LogBackfill.run()

      assert [job] = build_jobs()
      assert job.args["package"] == "rebuildme"
      assert job.args["version"] == "1.0.0"
      # Without this the build host's own dedup throws the job away: a `Run`
      # already exists for every package this module enqueues.
      assert job.args["force"] == true
      # The current digest is only resolvable on the machine holding the image.
      refute Map.has_key?(job.args, "image_digest")
      # A person waiting on a scan request they submitted never sits behind a
      # sweep that runs for nine hours.
      assert job.priority == 9
    end

    test "dry_run reports the candidates without enqueueing" do
      p = package("dry")
      p |> run() |> system_result(:fail)

      assert {:ok, %{candidates: 1, enqueued: 0}} = LogBackfill.run(dry_run: true)
      assert build_jobs() == []
    end

    test "limit caps the sweep" do
      for name <- ["a", "b", "c"] do
        name |> package() |> run() |> system_result(:fail)
      end

      assert {:ok, %{candidates: 2, enqueued: 2}} = LogBackfill.run(limit: 2)
      assert length(build_jobs()) == 2
    end
  end
end
