defmodule Portal.Builders.RemoteIntegrationTest do
  @moduledoc """
  `Portal.Builders.AgentE2ETest` against the real worker container: a real
  agent process claims a `RemoteBuild` lease for jason 1.4.4, runs
  `ncc-worker:local` through Docker with the post-isolation argv, uploads
  and completes, and `Ingest` writes the run as
  `Portal.Workers.BuildIntegrationTest` expects it, plus the builder and the
  publishing gate.

  `images.json` names the local image by its bare name and local digest
  (`Portal.Builder.image_digest/1`); `NccAgent.Job.image_ref/1` uses a bare
  name as is, so nothing is pulled. The egress script is a stub that exits
  0: a workstation has no `DOCKER-USER` chain to install `NCC-EGRESS` into,
  and the test is about the build path, not the firewall.

  Excluded by default; run with `make test-remote-integration` or

      mix test apps/portal/test/portal/builders/remote_integration_test.exs --only integration

  Requires: Docker running for this user, `ncc-worker:local` built
  (`make build`), network access to Hex.pm. The agent mounts its own Nerves
  cache under a temp data dir, so expect a cold build.
  """
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builder
  alias Portal.Builders
  alias Portal.Builders.AgentHarness
  alias Portal.Catalog
  alias Portal.Catalog.{Package, Run, SystemResult}
  alias Portal.Workers.{Ingest, RemoteBuild}

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  setup do
    assert docker_running?(), "docker daemon is not running"
    assert image_built?(), "#{Builder.docker_image()} not built — run: make build"
    :ok
  end

  test "a real agent builds jason 1.4.4 in the worker container and the portal ingests it" do
    image = Builder.docker_image()
    digest = Builder.image_digest(image)
    portal = AgentHarness.start_portal!(%{image: image, digest: digest})

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

    {:ok, %{token: token}} = Builders.create_token("it-box", "integration")

    agent =
      AgentHarness.start_agent!(portal, [
        {"NCC_ENROLMENT_TOKEN", token},
        {"NCC_DOCKER_BIN", System.find_executable("docker")},
        {"NCC_EGRESS_SCRIPT", AgentHarness.egress_stub!(portal.dir)}
      ])

    lease =
      AgentHarness.await_lease(
        agent,
        request.id,
        &(&1.state == :done and AgentHarness.ingest_job(&1) != nil),
        :timer.minutes(25)
      )

    AgentHarness.stop_agent(agent)

    {:ok, builder} = Builders.get_builder(lease.builder_id)
    job = AgentHarness.ingest_job(lease)
    assert :ok = perform_job(Ingest, job.args)

    package = Enum.find(Ash.read!(Package, domain: Catalog), &(&1.name == "jason"))
    assert package, "expected a Package row for jason"
    assert package.native_components["compatibility_basis"] == "pure_elixir"

    run =
      Run
      |> Ash.Query.filter(run_id == ^lease.run_id)
      |> Ash.read_one!(domain: Catalog)

    assert run, "expected a Run for #{lease.run_id}"
    assert run.builder_id == builder.id
    assert run.image_digest == digest
    assert run.overall_status == :pass
    assert %{"decimal" => %{"version" => _, "checksum" => _}} = run.deps_lock

    system_results =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Catalog)

    assert Enum.sort(Enum.map(system_results, & &1.system_pkg)) == ["host", "pure_elixir"]
    assert Enum.all?(system_results, &(&1.status == :pass))

    pure = Enum.find(system_results, &(&1.system_pkg == "pure_elixir"))
    published = get_in(pure.beam_scan, ["footprint", "file_manifest", "ebin"]) || []
    assert published != []

    for %{"sha256" => sha} <- published do
      assert Portal.ArtifactStore.present?(sha), "artifact #{sha} was not uploaded"
    end

    {:ok, updated} = Portal.ScanRequests.get_request(request.id)
    assert updated.status == :built
    assert updated.run_id == run.id

    assert Catalog.precompiled_manifest("jason") == nil
    {:ok, _builder} = Builders.set_publishing(builder, true)
    assert %{versions: %{"1.4.4" => _}} = Catalog.precompiled_manifest("jason")
  end

  defp docker_running? do
    match?(
      {_, 0},
      System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true)
    )
  end

  defp image_built? do
    match?(
      {_, 0},
      System.cmd("docker", ["image", "inspect", Builder.docker_image()], stderr_to_stdout: true)
    )
  end
end
