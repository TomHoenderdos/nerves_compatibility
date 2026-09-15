defmodule Portal.CatalogSeedTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.Package
  alias Portal.CatalogSeed
  alias Portal.Workers.Backfill

  setup do
    Application.put_env(:portal, :hex_registry_source, __MODULE__.StubRegistry)
    on_exit(fn -> Application.delete_env(:portal, :hex_registry_source) end)
    :ok
  end

  defmodule StubRegistry do
    def snapshot do
      case Process.get(:hex_answer, {:ok, []}) do
        {:ok, names} ->
          {:ok, Enum.map(names, &%{name: &1, latest_version: "1.0.0", updated_at: nil})}

        other ->
          other
      end
    end
  end

  defp registry_has(names), do: Process.put(:hex_answer, {:ok, names})

  defp package(name) do
    Ash.create!(Package, %{name: name, latest_version: "1.0.0"},
      action: :create,
      domain: Portal.Catalog
    )
  end

  describe "run/1" do
    test "enqueues only registry packages the catalogue does not have" do
      package("known")
      registry_has(["known", "missing_a", "missing_b"])

      assert {:ok, report} = CatalogSeed.run()
      assert report == %{registry: 3, known: 1, missing: 2, enqueued: 2}

      assert_enqueued(worker: Backfill, args: %{package: "missing_a"})
      assert_enqueued(worker: Backfill, args: %{package: "missing_b"})
      refute_enqueued(worker: Backfill, args: %{package: "known"})
    end

    # The whole reason this module exists separately from `UpdateCheck` is that
    # its jobs must not outrank a new release of a package already on the site.
    # The source is what carries that, so it is asserted rather than assumed.
    test "tags jobs as catalog_seed so they take the lowest build priority" do
      registry_has(["absent"])

      assert {:ok, _} = CatalogSeed.run()
      assert_enqueued(worker: Backfill, args: %{package: "absent", source: "catalog_seed"})
    end

    # Twenty thousand version lookups arriving at once is an outage we would be
    # causing, so the spacing is part of the contract, not a detail.
    test "staggers jobs so hex.pm is not asked for every version at once" do
      registry_has(["a", "b", "c"])

      assert {:ok, _} = CatalogSeed.run(stagger_ms: 1000)

      scheduled =
        Portal.Repo.all(Oban.Job)
        |> Enum.filter(&(&1.worker == "Portal.Workers.Backfill"))
        |> Enum.map(& &1.scheduled_at)
        |> Enum.sort()

      assert length(scheduled) == 3
      first = List.first(scheduled)
      last = List.last(scheduled)
      assert DateTime.diff(last, first) >= 2
    end

    test "limit caps what is enqueued but still reports the full gap" do
      registry_has(["a", "b", "c"])

      assert {:ok, report} = CatalogSeed.run(limit: 1)
      assert report.missing == 3
      assert report.enqueued == 1
    end

    test "dry run reports the gap and enqueues nothing" do
      package("known")
      registry_has(["known", "absent"])

      assert {:ok, report} = CatalogSeed.run(dry_run: true)
      assert report == %{registry: 2, known: 1, missing: 1, enqueued: 0}
      refute_enqueued(worker: Backfill)
    end

    test "a registry failure is returned, not swallowed" do
      Process.put(:hex_answer, {:error, :timeout})

      assert {:error, :timeout} = CatalogSeed.run()
      refute_enqueued(worker: Backfill)
    end

    # Re-running is the normal case: the sweep is long enough that it will be
    # interrupted, and the recovery is to run it again.
    test "re-running does not duplicate work" do
      registry_has(["absent"])

      assert {:ok, %{enqueued: 1}} = CatalogSeed.run()
      assert {:ok, report} = CatalogSeed.run()

      assert report.missing == 1
      assert report.enqueued == 0
    end
  end
end
