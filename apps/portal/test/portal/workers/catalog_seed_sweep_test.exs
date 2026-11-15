defmodule Portal.Workers.CatalogSeedSweepTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.Package
  alias Portal.Workers.Backfill
  alias Portal.Workers.CatalogSeedSweep

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

  test "queues a Backfill job for every package the catalogue is missing" do
    package("known")
    registry_has(["known", "missing"])

    assert :ok = perform_job(CatalogSeedSweep, %{})

    assert_enqueued(worker: Backfill, args: %{package: "missing", source: "catalog_seed"})
    refute_enqueued(worker: Backfill, args: %{package: "known"})
  end

  # The one-off catalogue bootstrap staggered jobs 45 s apart so they would
  # not outrun the builder capacity of the time; the cron keeps the same
  # spacing rather than falling back to `CatalogSeed`'s 1 s default.
  test "staggers jobs the same 45 seconds apart the manual bootstrap used" do
    registry_has(["a", "b"])

    assert :ok = perform_job(CatalogSeedSweep, %{})

    scheduled =
      [worker: Backfill]
      |> all_enqueued()
      |> Enum.map(& &1.scheduled_at)
      |> Enum.sort()

    assert [first, second] = scheduled
    assert DateTime.diff(second, first) >= 44
  end

  test "a registry failure is returned so Oban retries" do
    Process.put(:hex_answer, {:error, :timeout})

    assert {:error, :timeout} = perform_job(CatalogSeedSweep, %{})
  end

  test "re-running the same day enqueues nothing new" do
    registry_has(["absent"])

    assert :ok = perform_job(CatalogSeedSweep, %{})
    assert :ok = perform_job(CatalogSeedSweep, %{})

    assert [worker: Backfill] |> all_enqueued() |> Enum.count(&(&1.args["package"] == "absent")) ==
             1
  end
end
