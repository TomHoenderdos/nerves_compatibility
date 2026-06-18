defmodule Orchestrator.QueueTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Queue

  setup do
    # Stop the application if it's running
    Application.stop(:orchestrator)

    # Use temporary files for testing
    queue_file = Path.join(System.tmp_dir!(), "test_queue_#{:rand.uniform(100_000)}.dets")
    checked_file = Path.join(System.tmp_dir!(), "test_checked_#{:rand.uniform(100_000)}.dets")

    Application.put_env(:orchestrator, :queue_file, queue_file)
    Application.put_env(:orchestrator, :checked_file, checked_file)

    {:ok, pid} = Queue.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(queue_file)
      File.rm_rf(checked_file)
    end)

    {:ok, queue: pid}
  end

  describe "enqueue/1" do
    test "enqueues a new package/version" do
      assert :ok = Queue.enqueue({"jason", "1.4.4"})
      assert Queue.size() == 1
    end

    test "does not enqueue duplicates" do
      assert :ok = Queue.enqueue({"jason", "1.4.4"})
      assert :ok = Queue.enqueue({"jason", "1.4.4"})
      assert Queue.size() == 1
    end

    test "returns already_checked if package was checked" do
      item = {"jason", "1.4.4"}
      Queue.enqueue(item)
      Queue.mark_checked(item)

      assert {:already_checked, _timestamp} = Queue.enqueue(item)
    end
  end

  describe "dequeue/0" do
    test "returns empty when queue is empty" do
      assert :empty = Queue.dequeue()
    end

    test "dequeues items in FIFO order" do
      Queue.enqueue({"jason", "1.4.4"})
      Queue.enqueue({"ecto", "3.10.0"})

      assert {:ok, {"jason", "1.4.4"}} = Queue.dequeue()
      assert {:ok, {"ecto", "3.10.0"}} = Queue.dequeue()
      assert :empty = Queue.dequeue()
    end

    test "dequeues priority requests before normal polling work" do
      Queue.enqueue({"normal_one", "1.0.0"})
      Queue.enqueue({"normal_two", "1.0.0"})
      Queue.request_rescan({"jason", "1.4.4"}, priority: :anonymous, source: :anonymous_turnstile)
      Queue.request_rescan({"ecto", "3.10.0"}, priority: :hex_owner, source: :hex_owner)

      assert {:ok, {"ecto", "3.10.0"}} = Queue.dequeue()
      assert {:ok, {"jason", "1.4.4"}} = Queue.dequeue()
      assert {:ok, {"normal_one", "1.0.0"}} = Queue.dequeue()
      assert {:ok, {"normal_two", "1.0.0"}} = Queue.dequeue()
    end

    test "priority request upgrades an existing queued normal item" do
      Queue.enqueue({"jason", "1.4.4"})
      Queue.enqueue({"ecto", "3.10.0"})

      Queue.request_rescan({"ecto", "3.10.0"}, priority: :hex_owner, source: :hex_owner)

      assert {:ok, {"ecto", "3.10.0"}} = Queue.dequeue()
      assert {:ok, {"jason", "1.4.4"}} = Queue.dequeue()
    end
  end

  describe "request_rescan/2" do
    test "can requeue an already checked package" do
      item = {"jason", "1.4.4"}
      Queue.enqueue(item)
      Queue.mark_checked(item)

      assert :ok = Queue.request_rescan(item, priority: :anonymous, source: :anonymous_turnstile)
      assert Queue.size() == 1
      assert {:ok, ^item} = Queue.dequeue()
    end

    test "stores request metadata" do
      Queue.request_rescan({"jason", "1.4.4"}, priority: :github_repo, source: :github_repo)

      assert [
               {{"jason", "1.4.4"},
                %{priority: :github_repo, source: :github_repo, requested_at: %DateTime{}}}
             ] = Queue.list_entries()
    end
  end

  describe "mark_checked/1" do
    test "marks an item as checked" do
      item = {"jason", "1.4.4"}
      Queue.enqueue(item)
      Queue.mark_checked(item)

      assert {:checked, _timestamp} = Queue.checked?(item)
    end

    test "removes item from queue when marked as checked" do
      item = {"jason", "1.4.4"}
      Queue.enqueue(item)
      assert Queue.size() == 1

      Queue.mark_checked(item)
      assert Queue.size() == 0
    end
  end

  describe "stats/0" do
    test "returns queue statistics" do
      Queue.enqueue({"jason", "1.4.4"})
      Queue.enqueue({"ecto", "3.10.0"})
      Queue.mark_checked({"phoenix", "1.7.0"})

      stats = Queue.stats()

      assert stats.queue_size == 2
      assert stats.checked_count == 1
      assert stats.next_item == {"jason", "1.4.4"}
    end
  end
end
