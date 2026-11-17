defmodule Portal.Workers.IngestQueueTest do
  use ExUnit.Case, async: true

  alias Portal.NodeQueue
  alias Portal.Workers.Ingest

  describe "new/2" do
    # The scratch dir a local build leaves is on this node's disk.
    test "puts a job on this node's own queue" do
      assert Ingest.new(%{"run_id" => "r"}).changes.queue == NodeQueue.name()
    end

    test "keeps a queue the caller names, as a remote build's complete does" do
      assert Ingest.new(%{"run_id" => "r"}, queue: :remote).changes.queue == "remote"
    end
  end

  describe "builder_queues/1" do
    # What a builder deploy pauses and drains before restarting
    # (ops/builder-deploy.sh). A build that finishes while draining enqueues
    # its ingest on the node queue; leaving that queue out would restart the
    # node in the middle of that ingest. There is no shared ingest queue to
    # drain: none runs, and the deploy refuses a listed queue with no producer.
    test "a build node drains builds, its node queue, its old ingest queue, its warm and system ABI queues" do
      assert Ingest.builder_queues(:"portal@host-c", builds: 3, ingest: 2) ==
               [
                 "builds",
                 "node_portal_host_c",
                 "ingest_portal_host_c",
                 "warm_nerves_portal_host_c",
                 "system_abi"
               ]
    end

    # Only when the node runs it: `Oban.check_queue/1` finds no producer for a
    # queue the node does not run, and the deploy then refuses to go ahead.
    test "a build node running the toolchain queue drains it too" do
      assert Ingest.builder_queues(:"portal@host-c", builds: 3, ingest: 2, toolchain: 1) ==
               [
                 "builds",
                 "node_portal_host_c",
                 "ingest_portal_host_c",
                 "warm_nerves_portal_host_c",
                 "system_abi",
                 "toolchain"
               ]

      assert Ingest.builder_queues(:"portal@host-c", builds: 3, toolchain: 0) ==
               [
                 "builds",
                 "node_portal_host_c",
                 "ingest_portal_host_c",
                 "warm_nerves_portal_host_c",
                 "system_abi"
               ]
    end
  end

  describe "builder_queues/1 and toolchain_big" do
    test "a node running toolchain_big drains it, one without does not list it" do
      assert Ingest.builder_queues(:"portal@host-c",
               builds: 1,
               toolchain: 1,
               toolchain_big: 1
             ) == [
               "builds",
               "node_portal_host_c",
               "ingest_portal_host_c",
               "warm_nerves_portal_host_c",
               "system_abi",
               "toolchain",
               "toolchain_big"
             ]

      refute "toolchain_big" in Ingest.builder_queues(:"portal@host-c", builds: 1, toolchain: 1)

      refute "toolchain_big" in Ingest.builder_queues(:"portal@host-c",
               builds: 1,
               toolchain_big: 0
             )
    end
  end

  describe "builder_queues/1 and host_native" do
    setup do
      Application.put_env(:portal, Portal.HostNative, triple: "aarch64-linux-gnu")
      on_exit(fn -> Application.delete_env(:portal, Portal.HostNative) end)
    end

    test "a node running its own architecture's host-native queue drains it" do
      assert List.last(Ingest.builder_queues(:"portal@host-c", builds: 1, host_native_aarch64: 1)) ==
               "host_native_aarch64"

      refute "host_native_x86_64" in Ingest.builder_queues(:"portal@host-c",
               builds: 1,
               host_native_x86_64: 1
             )

      refute "host_native_aarch64" in Ingest.builder_queues(:"portal@host-c", builds: 1)
    end
  end
end
