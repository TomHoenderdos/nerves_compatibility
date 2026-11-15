defmodule Portal.Toolchains.MemoryRoutingTest do
  use Portal.DataCase, async: false

  import Portal.Test.RunMemoryFixtures

  alias Portal.Toolchains.MemoryRouting
  alias Portal.Workers.ToolchainBuild

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024

  @live [%{"queue" => "toolchain_big", "local_limit" => 1, "paused" => false}]

  defp toolchain_run!(package, attrs) do
    insert_run_memory!(
      Map.merge(
        %{
          kind: :toolchain,
          package: package,
          memory_limit_bytes: 2 * @gib,
          peak_used_bytes: 200 * @mib,
          finished_at: days_ago(1)
        },
        attrs
      )
    )
  end

  describe "big_packages/2" do
    test "an OOM kill in the window makes a package big" do
      toolchain_run!("ip2country", %{exit_code: 137, oom_killed: true, peak_used_bytes: nil})
      assert MemoryRouting.big_packages(["ip2country"]) == MapSet.new(["ip2country"])
    end

    test "a peak at 85% of the limit makes a package big, just under does not" do
      toolchain_run!("text", %{peak_used_bytes: ceil(2 * @gib * 0.85)})
      toolchain_run!("almost", %{peak_used_bytes: floor(2 * @gib * 0.84)})

      assert MemoryRouting.big_packages(["text", "almost"]) == MapSet.new(["text"])
    end

    test "a normal package, a firmware OOM and an OOM outside the window are not big" do
      toolchain_run!("jason", %{})
      insert_run_memory!(%{package: "exla", kind: :firmware, oom_killed: true, exit_code: 137})

      toolchain_run!("old", %{
        oom_killed: true,
        exit_code: 137,
        finished_at: days_ago(MemoryRouting.window_days() + 1)
      })

      assert MemoryRouting.big_packages(["jason", "exla", "old", "never_built"]) == MapSet.new()
    end

    test "any version or toolchain of the package counts" do
      toolchain_run!("han", %{version: "0.1.0", oom_killed: true, exit_code: 137})
      assert MapSet.member?(MemoryRouting.big_packages(["han"]), "han")
    end

    test "no packages, no query" do
      assert MemoryRouting.big_packages([]) == MapSet.new()
    end
  end

  describe "live?/1" do
    test "a producer for toolchain_big with a limit is live, paused or not" do
      assert MemoryRouting.live?(checks: fn -> @live end)

      assert MemoryRouting.live?(
               checks: fn ->
                 [%{"queue" => "toolchain_big", "local_limit" => 1, "paused" => true}]
               end
             )
    end

    test "other queues, a zero limit, or a failing lookup are not" do
      refute MemoryRouting.live?(checks: fn -> [] end)

      refute MemoryRouting.live?(
               checks: fn -> [%{"queue" => "toolchain", "local_limit" => 2}] end
             )

      refute MemoryRouting.live?(
               checks: fn -> [%{"queue" => "toolchain_big", "local_limit" => 0}] end
             )

      refute MemoryRouting.live?(checks: fn -> raise "no met" end)
      refute MemoryRouting.live?(checks: fn -> exit(:noproc) end)
    end
  end

  describe "router/2" do
    setup do
      toolchain_run!("ip2country", %{oom_killed: true, exit_code: 137})
      toolchain_run!("jason", %{})
      :ok
    end

    test "sends big packages to toolchain_big while a node runs it" do
      queue_for = MemoryRouting.router(["ip2country", "jason"], checks: fn -> @live end)
      assert queue_for.("ip2country") == :toolchain_big
      assert queue_for.("jason") == :toolchain
    end

    test "keeps everything on toolchain while no node runs toolchain_big" do
      queue_for = MemoryRouting.router(["ip2country", "jason"], checks: fn -> [] end)
      assert queue_for.("ip2country") == :toolchain
    end
  end

  describe "rescue_stranded/1" do
    defp big_job!(package, scheduled_at) do
      {:ok, job} =
        %{package: package, version: "1.0.0", toolchain: "1.19/28", builder_version: 1}
        |> ToolchainBuild.new(queue: :toolchain_big, scheduled_at: scheduled_at)
        |> Oban.insert()

      job
    end

    defp queue_of(job), do: Repo.get!(Oban.Job, job.id).queue

    test "moves jobs waiting on toolchain_big back once no node runs it" do
      waiting = big_job!("ip2country", DateTime.add(DateTime.utc_now(), -3600, :second))
      fresh = big_job!("han", DateTime.utc_now())

      assert MemoryRouting.rescue_stranded(checks: fn -> [] end) == 1
      assert queue_of(waiting) == "toolchain"
      assert queue_of(fresh) == "toolchain_big"
    end

    test "leaves them while a node runs toolchain_big" do
      waiting = big_job!("ip2country", DateTime.add(DateTime.utc_now(), -3600, :second))

      assert MemoryRouting.rescue_stranded(checks: fn -> @live end) == 0
      assert queue_of(waiting) == "toolchain_big"
    end
  end

  describe "with_checked_queue/1" do
    setup do
      previous = Application.get_env(:portal, Portal.Builder)
      on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
      %{previous: previous}
    end

    defp put_memory(previous, tmem, bmem) do
      Application.put_env(
        :portal,
        Portal.Builder,
        Keyword.merge(previous, memory: "3g", toolchain_memory: tmem, toolchain_big_memory: bmem)
      )
    end

    test "keeps toolchain_big when its limit is above the toolchain one", %{previous: previous} do
      put_memory(previous, "2g", "4g")
      config = [repo: Repo, queues: [builds: 1, toolchain: 1, toolchain_big: 1]]
      assert MemoryRouting.with_checked_queue(config) == config
    end

    test "drops toolchain_big at boot, with an error, when its limit is not above",
         %{previous: previous} do
      # Both unset: each is NCC_BUILD_MEMORY.
      put_memory(previous, nil, nil)
      config = [repo: Repo, queues: [builds: 1, toolchain: 1, toolchain_big: 1]]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert MemoryRouting.with_checked_queue(config)[:queues] == [builds: 1, toolchain: 1]
        end)

      assert log =~ "not running the toolchain_big queue"
      assert log =~ "NCC_TOOLCHAIN_BIG_MEMORY"
    end

    test "leaves a config without toolchain_big or without queues alone", %{previous: previous} do
      put_memory(previous, "2g", nil)
      assert MemoryRouting.with_checked_queue(queues: [builds: 1]) == [queues: [builds: 1]]
      assert MemoryRouting.with_checked_queue(testing: :manual) == [testing: :manual]
    end
  end

  describe "unique across the two queues" do
    @args %{
      package: "ip2country",
      version: "1.0.0",
      toolchain: "1.19/28",
      builder_version: 1,
      variant: "with",
      config_variant: "default"
    }

    test "a toolchain_big job conflicts with the same build on toolchain" do
      assert {:ok, %Oban.Job{conflict?: false}} = @args |> ToolchainBuild.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true, queue: "toolchain"}} =
               @args |> ToolchainBuild.new(queue: :toolchain_big) |> Oban.insert()
    end

    test "and the other way round" do
      assert {:ok, %Oban.Job{conflict?: false}} =
               @args |> ToolchainBuild.new(queue: :toolchain_big) |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true, queue: "toolchain_big"}} =
               @args |> ToolchainBuild.new() |> Oban.insert()
    end
  end
end
