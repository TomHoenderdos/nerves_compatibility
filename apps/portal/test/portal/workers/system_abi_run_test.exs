defmodule Portal.Workers.SystemAbiRunTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Portal.Catalog.SystemAbi, as: Row
  alias Portal.Workers.SystemAbiRun

  @rpi4 %{"system" => "nerves_system_rpi4", "version" => "2.3.0"}
  @bbb %{"system" => "nerves_system_bbb", "version" => "2.0.0"}
  @rpi3 %{"system" => "nerves_system_rpi3", "version" => "1.9.0"}

  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), {:system_abi_build, args})
      Process.get(:system_abi_response)
    end

    def cleanup(run_id) do
      send(self(), {:cleanup, run_id})
      :ok
    end
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    :ok
  end

  defp respond(entries, exit_code \\ 0) do
    Process.put(
      :system_abi_response,
      {:ok,
       %{
         exit_code: exit_code,
         result: %{"scope" => "system_abi", "systems" => %{}, "system_abi" => entries},
         files_dir: "",
         output_dir: "",
         log: ""
       }}
    )
  end

  defp attempt_ago!(pair, seconds) do
    Repo.query!(
      "UPDATE catalog_system_abi_attempts SET attempted_at = attempted_at - make_interval(secs => $3) " <>
        "WHERE system_pkg = $1 AND version = $2",
      [pair["system"], pair["version"], seconds]
    )
  end

  describe "enqueue/1" do
    test "puts at most eight pairs on the :system_abi queue" do
      assert {:ok, job} = SystemAbiRun.enqueue([@rpi4])
      assert job.queue == "system_abi"
      assert job.args == %{"pairs" => [@rpi4]}

      nine =
        for minor <- 0..8, do: %{"system" => "nerves_system_rpi4", "version" => "2.#{minor}.0"}

      assert {:error, :too_many_pairs} = SystemAbiRun.enqueue(nine)
    end
  end

  describe "schedule/2" do
    test "asks for a pair at most once a day" do
      assert {1, false} = SystemAbiRun.schedule([@rpi4], 10)
      assert {0, false} = SystemAbiRun.schedule([@rpi4], 10)

      attempt_ago!(@rpi4, 25 * 3600)
      Repo.delete_all(Oban.Job)
      assert {1, false} = SystemAbiRun.schedule([@rpi4], 10)
    end

    test "chunks eight pairs per run, up to the run limit" do
      pairs =
        for minor <- 0..20, do: %{"system" => "nerves_system_rpi4", "version" => "2.#{minor}.0"}

      assert {2, true} = SystemAbiRun.schedule(pairs, 2)
      assert [8, 8] = all_enqueued(worker: SystemAbiRun) |> Enum.map(&length(&1.args["pairs"]))
      assert {1, false} = SystemAbiRun.schedule(pairs, 2)
    end
  end

  describe "perform/1" do
    test "records the releases it read and runs no ingest" do
      respond([
        Map.merge(@rpi4, %{
          "toolchain" => %{
            "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
            "version" => "15.3.2"
          },
          "otp_full" => "28.1.2",
          "system_libs" => %{"libc.so.6" => ["GLIBC_2.17"]}
        })
      ])

      assert :ok = perform_job(SystemAbiRun, %{"pairs" => [@rpi4]})
      assert_received {:system_abi_build, %{mode: "system_abi", system_abi: [@rpi4]} = args}
      refute Map.has_key?(args, :package)
      assert_received {:cleanup, _run_id}

      row = Repo.one!(from(r in Row, where: r.system_pkg == "nerves_system_rpi4"))
      assert row.source == "lock" and row.libs == %{"libc.so.6" => ["GLIBC_2.17"]}
      assert all_enqueued(worker: Portal.Workers.Ingest) == []
    end

    test "a permanent error is never asked again, any other only after a day" do
      respond([
        Map.put(@rpi4, "error", "requires nerves 1"),
        Map.put(@bbb, "error", "no rootfs"),
        Map.put(@rpi3, "error", "deps.get failed")
      ])

      {1, false} = SystemAbiRun.schedule([@rpi4, @bbb, @rpi3], 10)
      [job] = all_enqueued(worker: SystemAbiRun)
      assert :ok = perform_job(SystemAbiRun, job.args)
      Repo.delete_all(Oban.Job)

      for pair <- [@rpi4, @bbb, @rpi3], do: attempt_ago!(pair, 25 * 3600)

      assert {1, false} = SystemAbiRun.schedule([@rpi4, @bbb, @rpi3], 10)
      assert [%{args: %{"pairs" => [@rpi3]}}] = all_enqueued(worker: SystemAbiRun)
    end

    test "every run has its own run id, even within one millisecond" do
      respond([])

      for _ <- 1..2, do: assert(:ok = perform_job(SystemAbiRun, %{"pairs" => [@rpi4]}))

      assert_received {:system_abi_build, %{run_id: first}}
      assert_received {:system_abi_build, %{run_id: second}}
      assert first != second
      assert_received {:cleanup, ^first}
      assert_received {:cleanup, ^second}

      {:ok, job} = SystemAbiRun.enqueue([@bbb])
      assert :ok = SystemAbiRun.perform(job)
      assert_received {:system_abi_build, %{run_id: run_id}}
      assert run_id =~ ~r/\Asystem_abi-#{job.id}-\d+\z/
    end

    test "a failed container is retried and the scratch dir is removed" do
      respond([], 10)

      capture_log(fn ->
        assert {:error, _} = perform_job(SystemAbiRun, %{"pairs" => [@rpi4]})
      end)

      assert_received {:cleanup, _run_id}
    end

    test "malformed args are cancelled" do
      assert {:cancel, _} = perform_job(SystemAbiRun, %{"pairs" => "nope"})
      assert {:cancel, _} = perform_job(SystemAbiRun, %{"pairs" => [%{"system" => 1}]})
    end
  end

  describe "with_queue/1" do
    test "adds the queue, limit 1, only where builds run" do
      assert SystemAbiRun.with_queue(queues: [builds: 3, ingest: 2])[:queues][:system_abi] == 1

      refute Keyword.has_key?(
               SystemAbiRun.with_queue(queues: [maintenance: 1])[:queues],
               :system_abi
             )
    end
  end
end
