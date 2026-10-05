defmodule Portal.Workers.BuildIntegrationTest do
  @moduledoc """
  End-to-end test: enqueue/perform a real `Portal.Workers.Build` for a small Hex
  package against the real `ncc-worker:local` container, then assert the Catalog
  rows land in Postgres.

  Replaces the standalone runner's `integration_test.exs` as the Docker-boundary
  gate. Excluded from `mix test` by default; run explicitly with:

      mix test --only integration

  Requires: Docker daemon running, `ncc-worker:local` built (`make build`), and
  network access to Hex.pm + the Nerves system artifact host. First run is slow
  (~10 min) while the x86_64 system artifact is cached into ~/.ncc-nerves-cache.
  """
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Builder
  alias Portal.Catalog.{Package, Run, SystemResult}
  alias Portal.ScanRequests
  alias Portal.Workers.{Build, Ingest}

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  @image "ncc-worker:local"

  setup do
    assert docker_running?(), "docker daemon is not running"
    assert image_built?(), "#{@image} not built — run: make build"
    :ok
  end

  test "classifies pure Elixir jason without firmware and ingests into Postgres" do
    {request, package, run} = build_and_ingest("jason", "1.4.4")

    assert package.native_components["compatibility_basis"] == "pure_elixir"
    assert run.overall_status == :pass

    # The default argus scope is firmware packages only, and jason is pure Elixir.
    assert run.argus["status"] == "skipped"

    # ≥1 SystemResult rows
    system_results =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Portal.Catalog)

    assert Enum.sort(Enum.map(system_results, & &1.system_pkg)) == ["host", "pure_elixir"]
    assert Enum.all?(system_results, &is_nil(&1.firmware_size_bytes))

    # Request marked built and linked to the run
    {:ok, updated} = ScanRequests.get_request(request.id)
    assert updated.status == :built
    assert updated.run_id == run.id
  end

  test "runs argus over the host beams when the scope covers the package" do
    {:ok, _} = Portal.Settings.save(%{argus_scope: "all"})

    # A different version from the test above, so the (package, version,
    # digest) dedupe never skips this build.
    {_request, _package, run} = build_and_ingest("jason", "1.4.3")

    assert run.argus["status"] == "ok", inspect(run.argus)
    assert run.argus["version"] == "0.20.1"
    assert is_list(run.argus["findings"])
  end

  defp build_and_ingest(name, version) do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: name,
        version: version,
        source: :hex_owner,
        status: :accepted
      })

    # Call perform/1 directly (not perform_job) so the ingestion transaction
    # runs in the test process, which owns the sandbox DB connection.
    job = %Oban.Job{
      args: %{
        "package" => name,
        "version" => version,
        "image_digest" => Builder.image_digest(@image),
        "scan_request_id" => request.id
      },
      attempt: 1,
      max_attempts: 3
    }

    assert :ok = Build.perform(job)

    # The build hands off to the ingest job; run it here for the same reason.
    assert [ingest_job] = all_enqueued(worker: Ingest)

    assert :ok =
             Ingest.perform(%Oban.Job{args: ingest_job.args, attempt: 1, max_attempts: 5})

    package = Enum.find(Ash.read!(Package, domain: Portal.Catalog), &(&1.name == name))
    assert package, "expected a Package row for #{name}"

    assert [run | _] =
             Run
             |> Ash.Query.filter(package_id == ^package.id and version_tested == ^version)
             |> Ash.read!(domain: Portal.Catalog)

    {request, package, run}
  end

  defp docker_running? do
    match?(
      {_, 0},
      System.cmd("docker", ["version", "--format", "{{.Server.Version}}"], stderr_to_stdout: true)
    )
  end

  defp image_built? do
    match?({_, 0}, System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true))
  end
end
