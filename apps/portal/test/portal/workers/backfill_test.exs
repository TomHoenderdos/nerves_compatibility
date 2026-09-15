defmodule Portal.Workers.BackfillTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  alias Portal.Workers.Backfill
  alias Portal.Workers.Build

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "9.9.9"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)
    :ok
  end

  # Oban stores the worker without the `Elixir.` prefix that `to_string/1` on a
  # module adds, so `inspect/1` is the form that actually matches the column.
  defp build_priority(package) do
    Portal.Repo.one!(
      from(j in Oban.Job,
        where: j.worker == ^inspect(Build),
        where: fragment("?->>'package'", j.args) == ^package,
        select: j.priority
      )
    )
  end

  describe "perform/1 source handling" do
    test "defaults to backfill when no source is given" do
      assert :ok = perform_job(Backfill, %{package: "sweep_pkg"})
      assert build_priority("sweep_pkg") == 9
    end

    # The split between these two numbers is load-bearing. Seeding the whole
    # registry inserts tens of thousands of rows; if a new release of a package
    # we already display shared their priority it would tie and lose on
    # insertion order, waiting months behind packages nobody has asked for.
    test "update_check outranks catalog_seed" do
      assert :ok = perform_job(Backfill, %{package: "fresh_pkg", source: "update_check"})
      assert :ok = perform_job(Backfill, %{package: "new_pkg", source: "catalog_seed"})

      assert build_priority("fresh_pkg") == 7
      assert build_priority("new_pkg") == 9
      assert build_priority("fresh_pkg") < build_priority("new_pkg")
    end

    # A typo must not quietly become the default priority -- that is exactly the
    # silent mis-scheduling the argument exists to prevent.
    test "an unknown source cancels rather than defaulting" do
      assert {:cancel, {:unknown_source, "typo"}} =
               perform_job(Backfill, %{package: "any_pkg", source: "typo"})

      refute_enqueued(worker: Build)
    end
  end
end
