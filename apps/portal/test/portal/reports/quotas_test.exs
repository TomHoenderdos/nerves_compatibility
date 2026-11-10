defmodule Portal.Reports.QuotasTest do
  use Portal.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Portal.Reports.Quotas
  alias Portal.Repo

  @day ~D[2026-11-10]

  defp reserve(keys, day \\ @day) do
    Repo.transaction(fn ->
      case Quotas.reserve(keys, day) do
        :ok -> :ok
        {:error, :cap} -> Repo.rollback(:cap)
      end
    end)
  end

  defp used(key, day \\ @day) do
    Repo.one(
      from(q in "precompiled_report_quotas",
        where: q.key == ^key and q.day == ^day,
        select: q.used
      )
    )
  end

  test "a key reserves up to its cap and no further" do
    assert {:ok, :ok} = reserve([{"package:jason", 3}])
    assert {:ok, :ok} = reserve([{"package:jason", 3}])
    assert {:ok, :ok} = reserve([{"package:jason", 3}])
    assert {:error, :cap} = reserve([{"package:jason", 3}])
    assert used("package:jason") == 3
  end

  test "a refused reservation takes nothing from the other keys" do
    assert {:ok, :ok} = reserve([{"reporter:a", 1}])
    assert {:error, :cap} = reserve([{"global", 50}, {"package:x", 3}, {"reporter:a", 1}])
    assert used("global") in [nil, 0]
    assert used("package:x") in [nil, 0]
  end

  test "a reservation the caller ends up not using is released by its rollback" do
    assert {:error, :not_queued} =
             Repo.transaction(fn ->
               :ok = Quotas.reserve([{"global", 50}, {"package:y", 3}], @day)
               Repo.rollback(:not_queued)
             end)

    assert used("global") in [nil, 0]
    assert used("package:y") in [nil, 0]
  end

  test "a committed reservation stays taken even if its build never runs" do
    assert {:ok, :ok} = reserve([{"package:z", 1}])
    assert {:error, :cap} = reserve([{"package:z", 1}])
    assert used("package:z") == 1
  end

  test "a new UTC day starts every key at zero" do
    assert {:ok, :ok} = reserve([{"global", 1}])
    assert {:error, :cap} = reserve([{"global", 1}])
    assert {:ok, :ok} = reserve([{"global", 1}], Date.add(@day, 1))
  end

  test "the defaults are 50 a day, 3 per package and 5 per reporter" do
    assert Quotas.caps() == %{global: 50, package: 3, reporter: 5}
  end

  test "configured caps override the defaults key by key" do
    previous = Application.get_env(:portal, Quotas)
    Application.put_env(:portal, Quotas, package: 7)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, Quotas, previous),
        else: Application.delete_env(:portal, Quotas)
    end)

    assert Quotas.caps() == %{global: 50, package: 7, reporter: 5}
  end

  test "prune drops the counters of earlier days" do
    {:ok, :ok} = reserve([{"global", 50}], Date.add(@day, -8))
    {:ok, :ok} = reserve([{"global", 50}], @day)
    assert Quotas.prune(Date.add(@day, -7)) == 1
    assert used("global") == 1
  end

  describe "under real concurrency" do
    # Outside the sandbox: each task holds its own connection and its own
    # transaction, as concurrent requeue jobs do. The key is unique to this
    # run and removed afterwards.
    setup do
      key = "global-concurrency-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(q in "precompiled_report_quotas", where: q.key == ^key))
        end)
      end)

      %{key: key}
    end

    test "60 jobs racing for a cap of 50 reserve exactly 50", %{key: key} do
      results =
        1..60
        |> Task.async_stream(
          fn _ -> Sandbox.unboxed_run(Repo, fn -> reserve([{key, 50}]) end) end,
          # At most 4 connections at once, well inside the test pool
          # (`System.schedulers_online() * 2`).
          max_concurrency: 4,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == {:ok, :ok})) == 50
      assert Enum.count(results, &(&1 == {:error, :cap})) == 10
      assert Sandbox.unboxed_run(Repo, fn -> used(key) end) == 50
    end
  end
end
