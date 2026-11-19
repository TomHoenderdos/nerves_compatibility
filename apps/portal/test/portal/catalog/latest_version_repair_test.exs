defmodule Portal.Catalog.LatestVersionRepairTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{LatestVersionRepair, Package, Run}

  defp package!(name, latest_version, last_run_at) do
    Package
    |> Ash.Changeset.for_create(:create, %{
      name: name,
      latest_version: latest_version,
      last_run_at: last_run_at
    })
    |> Ash.create!(domain: Catalog)
  end

  defp run!(package, version, finished_at, status \\ :pass) do
    Run
    |> Ash.Changeset.for_create(:create, %{
      run_id: "#{package.name}-#{System.unique_integer([:positive])}",
      package_id: package.id,
      version_tested: version,
      overall_status: status,
      finished_at: finished_at
    })
    |> Ash.create!(domain: Catalog)
  end

  defp latest!(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Map.take([:latest_version, :last_run_at])
  end

  # What an older release's forced build left before ingest became monotonic:
  # its run is the newest, and it set the package's latest version back.
  defp set_back!(name) do
    package = package!(name, "0.6.9", ~U[2026-11-17 10:00:00Z])
    run!(package, "0.6.10", ~U[2026-11-01 10:00:00Z])
    run!(package, "0.6.10", ~U[2026-11-02 10:00:00Z])
    run!(package, "0.6.9", ~U[2026-11-17 10:00:00Z], :fail)
    package
  end

  setup do
    set_back!("setback")

    # Behind its own release: a pre-release sorts below it.
    pre = package!("prerelease", "1.0.0-rc.1", ~U[2026-11-17 10:00:00Z])
    run!(pre, "1.0.0", ~U[2026-11-03 10:00:00Z])
    run!(pre, "1.0.0-rc.1", ~U[2026-11-17 10:00:00Z])

    # Already right: the latest is the highest, whatever was built last.
    right = package!("rightpkg", "2.0.0", ~U[2026-11-01 10:00:00Z])
    run!(right, "2.0.0", ~U[2026-11-01 10:00:00Z])
    run!(right, "1.9.0", ~U[2026-11-17 10:00:00Z])

    :ok
  end

  test "counts by default and writes nothing" do
    assert {:dry_run, changes} = LatestVersionRepair.repair()

    assert changes == [
             %{
               name: "prerelease",
               from: "1.0.0-rc.1",
               to: "1.0.0",
               from_last_run_at: ~U[2026-11-17 10:00:00Z],
               to_last_run_at: ~U[2026-11-03 10:00:00Z]
             },
             %{
               name: "setback",
               from: "0.6.9",
               to: "0.6.10",
               from_last_run_at: ~U[2026-11-17 10:00:00Z],
               to_last_run_at: ~U[2026-11-02 10:00:00Z]
             }
           ]

    assert latest!("setback") == %{latest_version: "0.6.9", last_run_at: ~U[2026-11-17 10:00:00Z]}
  end

  test "repairs the packages behind their highest version, once" do
    assert {:repaired, [_, _] = changes} = LatestVersionRepair.repair(dry_run: false)

    assert latest!("setback") == %{
             latest_version: "0.6.10",
             last_run_at: ~U[2026-11-02 10:00:00Z]
           }

    assert latest!("prerelease").latest_version == "1.0.0"
    assert latest!("rightpkg").latest_version == "2.0.0"

    # The page reads the repaired version's newest run again.
    assert Portal.Workers.Build.latest_version_tested("setback") == "0.6.10"

    assert {:repaired, []} = LatestVersionRepair.repair(dry_run: false)
    assert Enum.map(changes, & &1.name) == ["prerelease", "setback"]
  end

  test "repairs at most limit packages a call" do
    assert {:repaired, [%{name: "prerelease"}]} =
             LatestVersionRepair.repair(dry_run: false, limit: 1)

    assert {:repaired, [%{name: "setback"}]} =
             LatestVersionRepair.repair(dry_run: false, limit: 1)
  end

  test "undo puts back only the packages that still hold what it wrote" do
    {:repaired, changes} = LatestVersionRepair.repair(dry_run: false)

    # An ingest of a newer release since.
    Package
    |> Ash.Query.filter(name == "prerelease")
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:ingested, %{latest_version: "1.0.1"})
    |> Ash.update!(domain: Catalog)

    assert {:undone, 1} = LatestVersionRepair.undo(changes)

    assert latest!("setback") == %{latest_version: "0.6.9", last_run_at: ~U[2026-11-17 10:00:00Z]}
    assert latest!("prerelease").latest_version == "1.0.1"
  end
end
