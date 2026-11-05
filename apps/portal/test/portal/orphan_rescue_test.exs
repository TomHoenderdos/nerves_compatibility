defmodule Portal.OrphanRescueTest do
  use Portal.DataCase, async: false

  alias Portal.OrphanRescue
  alias Portal.Repo

  @this_node "portal@node-a"
  @other_node "portal@node-b"

  defp executing(worker, queue, node, opts \\ []) do
    Repo.insert!(%Oban.Job{
      worker: worker,
      queue: queue,
      state: Keyword.get(opts, :state, "executing"),
      args: %{},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      attempted_at: DateTime.utc_now(),
      attempted_by: [node, Ecto.UUID.generate()]
    })
  end

  defp reload(job), do: Repo.get!(Oban.Job, job.id)

  test "an executing batch this node attempted before it restarted is made available" do
    job = executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node)

    assert %{rescued: [id], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance, :intake])

    assert id == job.id
    assert reload(job).state == "available"
  end

  test "another node's executing batch is left alone" do
    job = executing("Portal.Workers.PrecompiledBatch", "maintenance", @other_node)

    assert %{rescued: [], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance])

    assert reload(job).state == "executing"
  end

  test "a boot with no orphans changes nothing" do
    available =
      executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node, state: "available")

    completed =
      executing("Portal.Workers.LeaseReaper", "maintenance", @this_node, state: "completed")

    assert %{rescued: [], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance])

    assert reload(available).state == "available"
    assert reload(completed).state == "completed"
  end

  test "an orphan on its last attempt is discarded, as Lifeline would, so cron can insert again" do
    job =
      executing("Portal.Workers.LeaseReaper", "maintenance", @this_node,
        attempt: 1,
        max_attempts: 1
      )

    assert %{rescued: [], discarded: [id]} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance])

    assert id == job.id
    job = reload(job)
    assert job.state == "discarded"
    assert job.discarded_at

    # The shape Oban appends on a failed attempt, so Oban Web shows why.
    assert [%{"attempt" => 1, "at" => at, "error" => "orphaned by node restart" <> _}] =
             job.errors

    assert {:ok, _, _} = DateTime.from_iso8601(at)
  end

  # Oban's `attempt_range` check constraint keeps `attempt <= max_attempts`, so
  # a row past it cannot exist; a batch on its last attempt is the edge.
  test "a batch orphaned on its last attempt is discarded" do
    job =
      executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node,
        attempt: 3,
        max_attempts: 3
      )

    assert %{rescued: [], discarded: [id]} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance])

    assert id == job.id
    assert reload(job).state == "discarded"
  end

  test "a row on a queue this node does not run is left alone, whatever its worker" do
    job = executing("Portal.Workers.PrecompiledBatch", "elsewhere", @this_node)

    assert %{rescued: [], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:maintenance])

    assert reload(job).state == "executing"
  end

  test "the default node name is the one this node's Oban stamps into attempted_by" do
    assert OrphanRescue.node_name() == Oban.config(Oban).node
  end

  test "it is started after the Repo and before Oban" do
    ids =
      Enum.map(Portal.Application.children(), fn child ->
        Supervisor.child_spec(child, []).id
      end)

    index = &Enum.find_index(ids, fn id -> id == &1 end)

    assert index.(Portal.Repo) < index.(OrphanRescue)
    assert index.(OrphanRescue) < index.(Oban)
  end

  test "workers off the allowlist are left to Lifeline" do
    build = executing("Portal.Workers.Build", "builds", @this_node)
    sweep = executing("Portal.Workers.ToolchainSweep", "maintenance", @this_node)

    assert %{rescued: [], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:builds, :maintenance])

    assert reload(build).state == "executing"
    assert reload(sweep).state == "executing"
  end

  test "a node that does not run the worker's queue leaves it alone" do
    job = executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node)

    assert %{rescued: [], discarded: []} =
             OrphanRescue.rescue_orphans(@this_node, [:builds, :ingest])

    assert reload(job).state == "executing"
  end

  describe "start_link/1, the boot hook" do
    defp oban_opts(extra) do
      :portal
      |> Application.fetch_env!(Oban)
      |> Keyword.merge(extra)
    end

    test "rescues this node's orphans and steps aside" do
      job = executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node)

      assert :ignore =
               OrphanRescue.start_link(
                 oban: oban_opts(testing: :disabled, node: @this_node, queues: [maintenance: 1])
               )

      assert reload(job).state == "available"
    end

    test "a rescue that exits, throws or raises never stops the boot" do
      oban = oban_opts(testing: :disabled, node: @this_node, queues: [maintenance: 1])

      for run <- [
            fn _, _ -> exit(:repo_down) end,
            fn _, _ -> throw(:boom) end,
            fn _, _ -> raise "boom" end
          ] do
        assert :ignore = OrphanRescue.start_link(oban: oban, run: run)
      end
    end

    test "does nothing while Oban runs in testing mode" do
      job = executing("Portal.Workers.PrecompiledBatch", "maintenance", @this_node)

      assert :ignore =
               OrphanRescue.start_link(
                 oban: oban_opts(testing: :manual, node: @this_node, queues: [maintenance: 1])
               )

      assert reload(job).state == "executing"
    end
  end
end
