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

  test "an argus-only rebuild keeps the previous result and adds fresh argus" do
    {_request, _package, first} = build_and_ingest("jason", "1.4.4")

    {request, package, second} =
      build_and_ingest("jason", "1.4.4", force: true, scope: "argus_only")

    systems = Portal.Catalog.latest_system_results(package.name) |> Map.new(&{&1.system_pkg, &1})
    assert systems["pure_elixir"].carried_from_run_id == first.id
    assert systems["host"].carried_from_run_id == nil
    assert second.argus["status"] in ["ok", "error"]
    assert request.status == :built
  end

  defp build_and_ingest(name, version, opts \\ []) do
    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: name,
        version: version,
        source: :hex_owner,
        status: :accepted
      })

    args =
      %{
        "package" => name,
        "version" => version,
        "image_digest" => Builder.image_digest(@image),
        "scan_request_id" => request.id
      }
      |> maybe_put("force", opts[:force] && true)
      |> maybe_put("scope", opts[:scope])

    # Call perform/1 directly (not perform_job) so the ingestion transaction
    # runs in the test process, which owns the sandbox DB connection.
    job = %Oban.Job{
      args: args,
      attempt: 1,
      max_attempts: 3
    }

    assert :ok = Build.perform(job)

    # The build hands off to the ingest job; run it here for the same reason.
    # Matched by scan_request_id, not just picked as the only one enqueued:
    # a second build_and_ingest call in the same test (the argus-only
    # rebuild) shares this sandbox transaction with the first, and that
    # first job's row is still "available" below.
    ingest_job =
      all_enqueued(worker: Ingest) |> Enum.find(&(&1.args["scan_request_id"] == request.id))

    assert ingest_job, "expected an Ingest job for scan_request #{request.id}"

    assert :ok =
             Ingest.perform(%Oban.Job{args: ingest_job.args, attempt: 1, max_attempts: 5})

    # `Ingest.perform/1` is called directly rather than through Oban's runner,
    # so its job row is never flipped out of "available" — delete it so it
    # does not get matched again by a later call in this test.
    Repo.delete!(ingest_job)

    package = Enum.find(Ash.read!(Package, domain: Portal.Catalog), &(&1.name == name))
    assert package, "expected a Package row for #{name}"

    # Sorted newest-first (same rule as `Catalog.Ingestion.previous_run/1`) so a
    # second call for the same version — the argus-only rebuild — picks up its
    # own run rather than the earlier full one.
    assert [run | _] =
             Run
             |> Ash.Query.filter(package_id == ^package.id and version_tested == ^version)
             |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
             |> Ash.read!(domain: Portal.Catalog)

    # The ingest job is what flips the request to `:built`; refetch so the
    # returned struct reflects that rather than the pre-build `:accepted` it
    # was created with.
    {:ok, request} = ScanRequests.get_request(request.id)

    {request, package, run}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
