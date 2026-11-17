defmodule Portal.NodeQueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.NodeQueue

  describe "name/1" do
    test "names a queue after the node" do
      assert NodeQueue.name(:"portal@host-c") == "node_portal_host_c"
      assert NodeQueue.name(:portal@buildhost1) == "node_portal_buildhost1"
    end

    test "differs per node, so one host never takes another's work" do
      refute NodeQueue.name(:"portal@host-a") == NodeQueue.name(:"portal@host-c")
    end

    test "defaults to this node" do
      assert NodeQueue.name() == NodeQueue.name(node())
    end
  end

  test "the previous release's ingest queue is named after the node too" do
    assert NodeQueue.legacy_ingest(:"portal@host-c") == "ingest_portal_host_c"
    assert NodeQueue.legacy_ingest() == NodeQueue.legacy_ingest(node())
  end

  describe "limit/1" do
    test "a node that runs builds runs its queue as wide as its node entry" do
      assert NodeQueue.limit(builds: 3, node: 3) == 3
    end

    # The hosts' OBAN_QUEUES still say `ingest:N` until the follow-up host
    # change; the node queue takes over that width.
    test "reads a legacy ingest entry as the node entry" do
      assert NodeQueue.limit(builds: 3, ingest: 4) == 4
      assert NodeQueue.limit(builds: 3, ingest: 4, node: 1) == 1
    end

    test "defaults the width when the node runs builds but names none" do
      assert NodeQueue.limit(builds: 1) == 2
    end

    test "a node that runs no builds has no node queue" do
      assert NodeQueue.limit(intake: 5, maintenance: 1) == nil
      assert NodeQueue.limit(builds: 0, node: 2) == nil
    end

    test "queues switched off (test mode) start nothing" do
      assert NodeQueue.limit(false) == nil
      assert NodeQueue.limit(nil) == nil
    end
  end

  describe "with_queue/2" do
    test "a build node gains its node queue, and for one release its old ingest queue" do
      config = [repo: Portal.Repo, queues: [builds: 3, node: 3]]

      assert NodeQueue.with_queue(config, :"portal@host-c")[:queues] ==
               [builds: 3, node_portal_host_c: 3, ingest_portal_host_c: 3]
    end

    # No shared ingest queue runs anywhere any more: that is what put each
    # hour's sweep on an arbitrary builder.
    test "a legacy ingest entry sizes the node queue, starts no shared queue, and says so" do
      config = [queues: [builds: 3, ingest: 2, toolchain: 1]]

      log =
        capture_log(fn ->
          assert NodeQueue.with_queue(config, :"portal@host-c")[:queues] ==
                   [builds: 3, toolchain: 1, node_portal_host_c: 2, ingest_portal_host_c: 2]
        end)

      assert log =~ "ingest:2"
      assert log =~ "node:2"
    end

    test "a web-only node's config is left alone" do
      config = [repo: Portal.Repo, queues: [intake: 5, maintenance: 1]]
      assert NodeQueue.with_queue(config, :portal@web) == config
    end

    test "a node that runs no builds drops a legacy ingest entry, and says so" do
      config = [queues: [intake: 5, ingest: 2]]

      log =
        capture_log(fn ->
          assert NodeQueue.with_queue(config, :portal@web)[:queues] == [intake: 5]
        end)

      assert log =~ "ingest:2"
    end

    test "test mode, with queues switched off, is left alone" do
      config = [testing: :manual]
      assert NodeQueue.with_queue(config, :nonode@nohost) == config
    end

    test "a queue an operator already listed is not added twice" do
      config = [queues: [builds: 1, node_portal_host_c: 4]]

      assert NodeQueue.with_queue(config, :"portal@host-c")[:queues] ==
               [builds: 1, node_portal_host_c: 4, ingest_portal_host_c: 2]
    end

    # Without distribution every build host is `nonode@nohost` and they would
    # all share one "node" queue -- the cross-host ingest this exists to
    # prevent. One unnamed node (dev, single-host installs) is fine, so it warns.
    test "warns when a build node has no node name" do
      log =
        capture_log(fn ->
          assert NodeQueue.with_queue([queues: [builds: 1]], :nonode@nohost)[:queues] ==
                   [builds: 1, node_nonode_nohost: 2, ingest_nonode_nohost: 2]
        end)

      assert log =~ "without a node name"
    end

    test "a named build node with a node entry starts quietly" do
      assert capture_log(fn ->
               NodeQueue.with_queue([queues: [builds: 1, node: 2]], :"portal@host-c")
             end) == ""
    end
  end
end
