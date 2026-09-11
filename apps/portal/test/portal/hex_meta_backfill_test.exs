defmodule Portal.HexMetaBackfillTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.Package
  alias Portal.HexMetaBackfill
  alias Portal.Workers.PackageMeta

  defp seed(name, attrs \\ %{}) do
    {:ok, package} =
      Package
      |> Ash.Changeset.for_create(:create, Map.merge(%{name: name}, attrs))
      |> Ash.create(domain: Portal.Catalog)

    package
  end

  defp mark_fetched(package) do
    {:ok, updated} =
      package
      |> Ash.Changeset.for_update(:update_hex_meta, %{hex_links: %{}, hex_owners: []})
      |> Ash.update(domain: Portal.Catalog)

    updated
  end

  defp enqueued_names do
    PackageMeta
    |> then(&all_enqueued(worker: &1))
    |> Enum.map(& &1.args["package"])
  end

  test "every package without metadata gets a job" do
    seed("jason")
    seed("plug")

    assert {:ok, %{candidates: 2, enqueued: 2}} = HexMetaBackfill.run(stagger_ms: 0)

    assert Enum.sort(enqueued_names()) == ["jason", "plug"]
  end

  # The default exists so the sweep can be re-run after a partial failure
  # without paying for every package again.
  test "a package already fetched is skipped by default" do
    seed("jason") |> mark_fetched()
    seed("plug")

    assert {:ok, %{candidates: 1, enqueued: 1}} = HexMetaBackfill.run(stagger_ms: 0)

    assert Enum.sort(enqueued_names()) == ["plug"]
  end

  test "only_missing: false re-fetches everything" do
    seed("jason") |> mark_fetched()
    seed("plug")

    assert {:ok, %{candidates: 2}} = HexMetaBackfill.run(only_missing: false, stagger_ms: 0)

    assert Enum.sort(enqueued_names()) == ["jason", "plug"]
  end

  # The dry run: ~2,500 packages is ~45 minutes of hex.pm traffic, so being able
  # to send three of them first is what makes the sweep safe to try.
  test "limit caps the sweep" do
    for name <- ~w(a b c d e), do: seed(name)

    assert {:ok, %{candidates: 2, enqueued: 2}} = HexMetaBackfill.run(limit: 2, stagger_ms: 0)

    assert Enum.sort(enqueued_names()) == ["a", "b"]
  end

  # hex.pm rate-limits, and the whole sweep is one request per package. Without
  # the stagger every job in the catalog becomes available at once.
  test "jobs are spread out rather than all made available at once" do
    for name <- ~w(a b c), do: seed(name)

    assert {:ok, %{enqueued: 3}} = HexMetaBackfill.run(stagger_ms: 1000)

    scheduled =
      all_enqueued(worker: PackageMeta)
      |> Enum.sort_by(& &1.args["package"])
      |> Enum.map(& &1.scheduled_at)

    # Seconds apart, not microseconds: insertion order alone would satisfy a
    # bare "increasing" assertion while every job still became available at once.
    assert [first, second, third] = scheduled
    assert DateTime.diff(second, first, :second) >= 1
    assert DateTime.diff(third, second, :second) >= 1
  end

  test "an empty catalog is a no-op, not a failure" do
    assert {:ok, %{candidates: 0, enqueued: 0}} = HexMetaBackfill.run(stagger_ms: 0)
  end
end
