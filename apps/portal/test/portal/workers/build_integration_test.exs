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
  alias Portal.Workers.Build

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  @image "ncc-worker:local"

  setup do
    assert docker_running?(), "docker daemon is not running"
    assert image_built?(), "#{@image} not built — run: make build"
    :ok
  end

  test "builds jason against nerves_system_x86_64 and ingests into Postgres" do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    image_digest = Builder.image_digest(@image)

    assert :ok =
             perform_job(Build, %{
               "package" => "jason",
               "version" => "1.4.4",
               "image_digest" => image_digest,
               "scan_request_id" => request.id
             })

    # Package row
    packages = Ash.read!(Package, domain: Portal.Catalog)
    package = Enum.find(packages, &(&1.name == "jason"))
    assert package, "expected a Package row for jason"

    # Run row with a non-error overall status
    runs =
      Run
      |> Ash.Query.filter(package_id == ^package.id)
      |> Ash.read!(domain: Portal.Catalog)

    assert [run | _] = runs

    assert run.overall_status in [:pass, :fail, :skipped, :unknown],
           "overall_status should not be :error, got #{inspect(run.overall_status)}"

    # ≥1 SystemResult rows
    system_results =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Portal.Catalog)

    assert length(system_results) >= 1

    # Request marked built and linked to the run
    {:ok, updated} = ScanRequests.get_request(request.id)
    assert updated.status == :built
    assert updated.run_id == run.id
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
