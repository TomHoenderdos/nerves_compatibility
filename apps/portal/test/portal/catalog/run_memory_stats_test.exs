defmodule Portal.Catalog.RunMemoryStatsTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.RunMemory
  alias Portal.Catalog.RunMemoryStats

  @gib 1024 * 1024 * 1024

  import Portal.Test.RunMemoryFixtures

  describe "per_package/1" do
    setup do
      seed_run_memory!()
    end

    test "one line per package and kind over the last 30 days, warm runs left out" do
      rows = RunMemoryStats.per_package()
      keys = Enum.map(rows, &{&1.package, &1.kind})
      assert Enum.sort(keys) == [{"exla", :firmware}, {"jason", :firmware}, {"jason", :toolchain}]

      jason = Enum.find(rows, &(&1.package == "jason" and &1.kind == :firmware))
      assert jason.runs == 3
      assert jason.oom_kills == 0
      # The newest run with a peak, not the newest run.
      assert jason.last_peak_used_bytes == 2 * @gib
      assert jason.max_peak_used_bytes == 2 * @gib
      # percentile_cont(0.9) over [1, 2] GiB.
      assert jason.p90_peak_used_bytes == round(1.9 * @gib)
      assert jason.last_limit_bytes == 3 * @gib
      assert %DateTime{} = jason.last_finished_at
      assert DateTime.diff(DateTime.utc_now(), jason.last_finished_at, :hour) in 23..25
    end

    test "an OOM-killed run counts as peaking at the limit it died at" do
      exla = Enum.find(RunMemoryStats.per_package(), &(&1.package == "exla"))
      assert exla.runs == 2
      assert exla.oom_kills == 1
      assert exla.last_peak_used_bytes == 3 * @gib
      assert exla.max_peak_used_bytes == 3 * @gib
    end

    test "the default sort is the max peak, descending" do
      assert [{"exla", :firmware}, {"jason", :firmware}, {"jason", :toolchain}] =
               Enum.map(RunMemoryStats.per_package(), &{&1.package, &1.kind})
    end

    test "kind narrows, sort orders, limit caps" do
      assert [%{package: "jason", kind: :toolchain}] =
               RunMemoryStats.per_package(kind: :toolchain)

      assert length(RunMemoryStats.per_package(kind: :firmware)) == 2
      assert length(RunMemoryStats.per_package(kind: :all)) == 3

      assert [%{package: "exla"} | _] = RunMemoryStats.per_package(sort: :oom)
      assert [%{package: "jason", runs: 3} | _] = RunMemoryStats.per_package(sort: :runs)

      assert ["exla", "jason", "jason"] =
               Enum.map(RunMemoryStats.per_package(sort: :name), & &1.package)

      assert [_one] = RunMemoryStats.per_package(limit: 1)
    end
  end

  test "warm_summary/0 counts the warm runs of the last 30 days" do
    seed_run_memory!()
    assert RunMemoryStats.warm_summary() == %{runs: 2, max_peak_used_bytes: 700 * 1024 * 1024}
  end

  test "warm_summary/0 with no warm runs" do
    assert %{runs: 0, max_peak_used_bytes: nil} = RunMemoryStats.warm_summary()
  end

  describe "latest_for_package/1" do
    test "the newest firmware and toolchain rows, whatever their age" do
      insert_run_memory!(%{package: "jason", peak_used_bytes: 1, finished_at: days_ago(60)})
      insert_run_memory!(%{package: "jason", peak_used_bytes: 2, finished_at: days_ago(50)})

      insert_run_memory!(%{
        package: "jason",
        kind: :toolchain,
        peak_used_bytes: 3,
        finished_at: days_ago(1)
      })

      insert_run_memory!(%{package: "other", peak_used_bytes: 4, finished_at: days_ago(0)})

      assert %{
               firmware: %RunMemory{peak_used_bytes: 2},
               toolchain: %RunMemory{peak_used_bytes: 3}
             } = RunMemoryStats.latest_for_package("jason")
    end

    test "a missing kind is nil, a package with no rows is nil" do
      insert_run_memory!(%{package: "jason", peak_used_bytes: 2})

      assert %{firmware: %RunMemory{}, toolchain: nil} =
               RunMemoryStats.latest_for_package("jason")

      assert RunMemoryStats.latest_for_package("nothing") == nil
    end
  end
end
