defmodule Portal.Builders.AgentE2ETest do
  @moduledoc """
  The remote-builder path end to end, with the agent as a real OS process
  and only Docker faked (`apps/ncc_agent/test/support/fake_docker.sh`):
  `RemoteBuild` writes a lease, the agent enrols over the mTLS listener with
  a minted token, claims, "builds", uploads the precompiled file it lacks
  and completes; the `Ingest` job the completion enqueued writes the run
  with its builder, and the precompiled manifest waits for the builder's
  publishing flag.

  Excluded by default; run with `make test-remote-e2e` or

      mix test apps/portal/test/portal/builders/agent_e2e_test.exs --only e2e

  The first run compiles `ncc_agent` in the test env, which takes a while.
  """
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builders
  alias Portal.Builders.AgentHarness
  alias Portal.Catalog
  alias Portal.Catalog.Run
  alias Portal.Workers.{Ingest, RemoteBuild}

  @moduletag :e2e
  @moduletag timeout: :timer.minutes(5)

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
  @digest "sha256:" <> String.duplicate("e2", 32)

  test "a lease is claimed, built, uploaded and ingested by a real agent process" do
    portal = AgentHarness.start_portal!(%{image: "ncc-worker:local", digest: @digest})

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    assert :ok =
             perform_job(RemoteBuild, %{
               "package" => "jason",
               "version" => "1.4.4",
               "scan_request_id" => request.id
             })

    {:ok, %{token: token}} = Builders.create_token("e2e-box", "e2e")

    # The run id is only known once the lease is claimed; Ingest takes it
    # from the job args, not from result.json.
    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["package", "version"], "1.4.4")
      |> Jason.encode!()

    _ = File.rm(Portal.ArtifactStore.blob_path(@sha))

    agent =
      AgentHarness.start_agent!(portal, [
        {"NCC_ENROLMENT_TOKEN", token},
        {"NCC_DOCKER_BIN", AgentHarness.fake_docker()},
        {"NCC_EGRESS_SCRIPT", AgentHarness.egress_stub!(portal.dir)},
        {"FAKE_DOCKER_RESULT", result},
        # The fake names the file by the sha256 of its content: this is @sha.
        {"FAKE_DOCKER_FILE_CONTENT", "precompiled-beam"},
        {"FAKE_DOCKER_IMAGE_PRESENT", "1"},
        # A current worker image, so the run takes the read-only Hex mount.
        {"FAKE_DOCKER_HEX_LABEL", "seeded"}
      ])

    lease =
      AgentHarness.await_lease(
        agent,
        request.id,
        &(&1.state == :done and AgentHarness.ingest_job(&1) != nil),
        120_000
      )

    # Nothing else is queued; stop the agent before ingest so no request
    # handler shares the sandbox connection with it.
    AgentHarness.stop_agent(agent)

    assert lease.builder_id
    assert lease.attempt == 1
    {:ok, builder} = Builders.get_builder(lease.builder_id)
    assert builder.name == "e2e-box"
    assert builder.egress_status == "ok"

    job = AgentHarness.ingest_job(lease)
    assert job.queue == "remote"
    assert job.args["builder_id"] == builder.id
    assert job.args["image_digest"] == @digest
    assert :ok = perform_job(Ingest, job.args)

    run =
      Run
      |> Ash.Query.filter(run_id == ^lease.run_id)
      |> Ash.read_one!(domain: Portal.Catalog)

    assert run, "expected a Run for #{lease.run_id}"
    assert run.builder_id == builder.id
    assert run.image_digest == @digest
    assert run.version_tested == "1.4.4"
    assert Portal.ArtifactStore.present?(@sha)
    assert File.read!(Portal.ArtifactStore.blob_path(@sha)) == "precompiled-beam"

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :built
    assert updated.run_id == run.id

    # A new builder does not publish until an admin has inspected its runs.
    assert Catalog.precompiled_manifest("jason") == nil
    {:ok, _builder} = Builders.set_publishing(builder, true)
    assert %{versions: %{"1.4.4" => _}} = Catalog.precompiled_manifest("jason")
  end
end
