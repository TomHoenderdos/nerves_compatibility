defmodule Portal.Workers.IngestQueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.Workers.Ingest

  describe "local_queue/1" do
    test "names a queue after the node" do
      assert Ingest.local_queue(:"portal@box-c") == "ingest_portal_box_c"
      assert Ingest.local_queue(:portal@vmi3525942) == "ingest_portal_vmi3525942"
    end

    test "differs per node, so one host never takes another's ingest" do
      refute Ingest.local_queue(:"portal@box-a") == Ingest.local_queue(:"portal@box-c")
    end

    test "defaults to this node" do
      assert Ingest.local_queue() == Ingest.local_queue(node())
    end
  end

  describe "builder_queues/1" do
    # What a builder deploy pauses and drains before restarting
    # (ops/builder-deploy.sh). A build that finishes while draining enqueues
    # its ingest on the local queue; leaving that queue out would restart the
    # node in the middle of that ingest.
    test "a build node drains builds, the shared ingest queue and its own" do
      assert Ingest.builder_queues(:"portal@box-c") ==
               ["builds", "ingest", "ingest_portal_box_c"]
    end
  end

  describe "with_local_queue/2" do
    test "a build node's Oban config gains its own ingest queue" do
      config = [repo: Portal.Repo, queues: [builds: 3, ingest: 3]]

      assert Ingest.with_local_queue(config, :"portal@box-c")[:queues] ==
               [builds: 3, ingest: 3, ingest_portal_box_c: 3]
    end

    test "a web-only node's config is left alone" do
      config = [repo: Portal.Repo, queues: [intake: 5, maintenance: 1]]
      assert Ingest.with_local_queue(config, :portal@web) == config
    end

    test "test mode, with queues switched off, is left alone" do
      config = [testing: :manual]
      assert Ingest.with_local_queue(config, :nonode@nohost) == config
    end

    test "a queue an operator already listed is not added twice" do
      config = [queues: [builds: 1, ingest_portal_box_c: 4]]

      assert Ingest.with_local_queue(config, :"portal@box-c")[:queues] ==
               [builds: 1, ingest_portal_box_c: 4]
    end

    # Without distribution every build host is `nonode@nohost` and they would all
    # share one "local" queue -- the cross-host ingest this exists to prevent.
    # One unnamed node (dev, single-host installs) is fine, so it warns.
    test "warns when a build node has no node name" do
      log =
        capture_log(fn ->
          assert Ingest.with_local_queue([queues: [builds: 1]], :nonode@nohost)[:queues] ==
                   [builds: 1, ingest_nonode_nohost: 2]
        end)

      assert log =~ "without a node name"
    end

    test "a named build node starts quietly" do
      assert capture_log(fn ->
               Ingest.with_local_queue([queues: [builds: 1]], :"portal@box-c")
             end) ==
               ""
    end
  end

  describe "local_queue_limit/1" do
    test "a node that runs builds runs its own ingest queue, as wide as :ingest" do
      assert Ingest.local_queue_limit(builds: 3, ingest: 3) == 3
    end

    test "defaults the width when the node runs builds but no shared :ingest" do
      assert Ingest.local_queue_limit(builds: 1) == 2
    end

    test "a node that runs no builds has nothing to ingest locally" do
      assert Ingest.local_queue_limit(intake: 5, maintenance: 1) == nil
      assert Ingest.local_queue_limit(builds: 0, ingest: 2) == nil
    end

    test "queues switched off (test mode) start nothing" do
      assert Ingest.local_queue_limit(false) == nil
      assert Ingest.local_queue_limit(nil) == nil
    end
  end
end
