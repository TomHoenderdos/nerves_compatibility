defmodule Portal.Workers.UpdateCheckTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  alias Portal.Catalog.Package
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
end
