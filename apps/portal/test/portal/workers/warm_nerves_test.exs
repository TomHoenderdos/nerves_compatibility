defmodule Portal.Workers.WarmNervesTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query, only: [from: 2]

  alias Portal.Workers.WarmNerves

  @pairs [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}]

  defmodule StubBuilder do
    @ok {:ok,
         %{
           exit_code: 0,
           result: %{"warm" => %{"installed" => [], "replaced" => [], "not_warmed" => []}},
           files_dir: "",
           output_dir: "",
           log: ""
         }}

    def build(args, _opts \\ []) do
      send(self(), {:warm_build, args})
      Process.get(:warm_response, @ok)
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

  defp set_state!(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end

  describe "enqueue/2" do
    test "puts the job on this node's own queue" do
      assert {:ok, job} = WarmNerves.enqueue("sha256:x", @pairs)
      assert job.queue == WarmNerves.local_queue()
      assert job.args == %{"image_digest" => "sha256:x", "pairs" => @pairs}
    end

    test "is unique per digest and pairs for a day, completed jobs included" do
      {:ok, first} = WarmNerves.enqueue("sha256:x", @pairs)

      {:ok, again} = WarmNerves.enqueue("sha256:x", @pairs)
      assert again.conflict?
      assert again.id == first.id

      set_state!(first, "completed")
      {:ok, after_done} = WarmNerves.enqueue("sha256:x", @pairs)
      assert after_done.conflict?
    end

    test "other pairs or another image are separate jobs" do
      {:ok, first} = WarmNerves.enqueue("sha256:x", @pairs)

      {:ok, other_pairs} =
        WarmNerves.enqueue("sha256:x", [%{"name" => "nerves_system_bbb", "version" => "2.0.0"}])

      {:ok, other_image} = WarmNerves.enqueue("sha256:y", @pairs)

      refute other_pairs.conflict?
      refute other_image.conflict?
      assert length(Enum.uniq([first.id, other_pairs.id, other_image.id])) == 3
    end

    # A warm that failed (Hex down, a bad download) must not block its retry
    # until tomorrow.
    test "a discarded or cancelled warm does not block the next one" do
      for state <- ["discarded", "cancelled"] do
        Repo.delete_all(Oban.Job)
        {:ok, first} = WarmNerves.enqueue("sha256:x", @pairs)
        set_state!(first, state)

        {:ok, retry} = WarmNerves.enqueue("sha256:x", @pairs)
        refute retry.conflict?, "a #{state} warm blocked the next"
      end
    end
  end

  describe "the node-local queue" do
    test "is named after the node" do
      assert WarmNerves.local_queue(:"portal@host-c") == "warm_nerves_portal_host_c"
      assert WarmNerves.local_queue() == WarmNerves.local_queue(node())
    end

    test "a build node gets it with concurrency 1" do
      config = [queues: [builds: 3, ingest: 2]]

      assert WarmNerves.with_local_queue(config, :"portal@host-c")[:queues] ==
               [builds: 3, ingest: 2, warm_nerves_portal_host_c: 1]
    end

    test "a web-only node and test mode are left alone" do
      web = [queues: [intake: 5, maintenance: 1]]
      assert WarmNerves.with_local_queue(web, :portal@web) == web
      assert WarmNerves.with_local_queue([testing: :manual], :nonode@nohost) == [testing: :manual]
    end
  end

  describe "perform/1" do
    test "runs the worker in warm mode with the pairs, then removes its scratch" do
      assert :ok = perform_job(WarmNerves, %{"image_digest" => "sha256:x", "pairs" => @pairs})

      assert_received {:warm_build,
                       %{
                         mode: "warm_nerves",
                         nerves_packages: @pairs,
                         image_digest: "sha256:x",
                         run_id: "warm_nerves-" <> _ = run_id
                       }}

      assert_received {:cleanup, ^run_id}
    end

    test "a failed container is retried" do
      Process.put(
        :warm_response,
        {:ok, %{exit_code: 10, result: nil, files_dir: "", output_dir: "", log: ""}}
      )

      assert {:error, _} =
               perform_job(WarmNerves, %{"image_digest" => "sha256:x", "pairs" => @pairs})

      assert_received {:cleanup, _}
    end

    test "a full disk snoozes rather than spending attempts" do
      Process.put(:warm_response, {:error, {:insufficient_disk, 1, 2}})

      assert {:snooze, 900} =
               perform_job(WarmNerves, %{"image_digest" => "sha256:x", "pairs" => @pairs})
    end

    test "a missing egress filter snoozes rather than spending attempts" do
      Process.put(:warm_response, {:error, :egress_filter_missing})

      assert {:snooze, 900} =
               perform_job(WarmNerves, %{"image_digest" => "sha256:x", "pairs" => @pairs})

      assert_received {:cleanup, _run_id}
    end

    test "a host without a build memory limit snoozes rather than spending attempts" do
      Process.put(:warm_response, {:error, :build_memory_limit_missing})

      assert {:snooze, 900} =
               perform_job(WarmNerves, %{"image_digest" => "sha256:x", "pairs" => @pairs})

      assert_received {:cleanup, _run_id}
    end

    test "malformed args are cancelled" do
      assert {:cancel, _} = perform_job(WarmNerves, %{"image_digest" => "sha256:x"})
      refute_received {:warm_build, _}
    end
  end
end
