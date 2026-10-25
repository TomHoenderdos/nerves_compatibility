defmodule Portal.Workers.BuildIntegrationTest do
  @moduledoc """
  End-to-end test: enqueue/perform a real `Portal.Workers.Build` for a small Hex
  package against the real worker container (`Portal.Builder.docker_image/0`,
  `ncc-worker:local` unless `NCC_DOCKER_IMAGE` names another), then assert the
  Catalog rows land in Postgres.

  Replaces the standalone runner's `integration_test.exs` as the Docker-boundary
  gate. Excluded from `mix test` by default; run explicitly with:

      mix test --only integration

  Requires: Docker daemon running, `ncc-worker:local` built (`make build`), and
  network access to Hex.pm + the Nerves system artifact host. The Nerves cache
  test runs the deploy-time warm, which on its first run empties the configured
  Nerves cache (`Portal.Builder.nerves_cache/0`: a temp dir under `config/test.exs`,
  ~/.ncc-nerves-cache elsewhere unless NCC_NERVES_CACHE names another) of
  entries builds wrote and downloads every default target's artifacts, about 2 GB.
  """
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Compatibility.BuildCacheKey
  alias Portal.Builder
  alias Portal.Catalog.{Package, Run, SystemResult}
  alias Portal.ScanRequests
  alias Portal.Workers.{Build, Ingest, WarmNerves}

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  setup do
    assert docker_running?(), "docker daemon is not running"
    assert image_built?(), "#{Builder.docker_image()} not built — run: make build"
    :ok
  end

  test "classifies pure Elixir jason without firmware and ingests into Postgres" do
    {request, package, run} = build_and_ingest("jason", "1.4.4")

    assert package.native_components["compatibility_basis"] == "pure_elixir"
    assert run.overall_status == :pass

    # The default argus scope is firmware packages only, and jason is pure Elixir.
    assert run.argus["status"] == "skipped"

    # jason's only dependency is an optional `decimal`. For a pure-Elixir
    # package the worker rebuilds the published files with its optional
    # dependencies resolved, so decimal is in the closure with the version and outer checksum the build locked: a client
    # matches the entry only when its own lock has that decimal too.
    assert %{"decimal" => %{"version" => version, "checksum" => checksum}} = run.deps_lock
    assert Version.match?(version, "~> 1.0 or ~> 2.0")
    assert is_binary(checksum)
    assert is_binary(run.package_checksum)

    # ≥1 SystemResult rows
    system_results =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.read!(domain: Portal.Catalog)

    # jason has no compile_env reads of its own.
    for result <- system_results, do: assert(result.compile_env == [])

    assert Enum.sort(Enum.map(system_results, & &1.system_pkg)) == ["host", "pure_elixir"]

    # decimal is added only for the published files: the status and the
    # pure-Elixir classification above come from the build without it.
    assert Enum.all?(system_results, &(&1.status == :pass))

    # The published files must be the ones compiled with decimal loadable:
    # jason only defines its Jason.Encoder implementation for Decimal then.
    pure = Enum.find(system_results, &(&1.system_pkg == "pure_elixir"))
    published = get_in(pure.beam_scan, ["footprint", "file_manifest", "ebin"]) || []
    assert Enum.any?(published, &(&1["path"] == "ebin/Elixir.Jason.Encoder.Decimal.beam"))
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
    assert run.argus["version"] == "0.24.0"
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

    # An argus-only run builds nothing, so it has no lock of its own.
    assert %{"decimal" => _} = first.deps_lock
    assert second.deps_lock == nil
    assert second.package_checksum == nil
    assert request.status == :built
  end

  # Build sandbox isolation spec, section 2: the container's /build-cache is
  # mounted read-only; the only writer is Portal.BuildCache.Promotion, which
  # runs on the host before Portal.Workers.Build hands the run off to ingest.
  # This proves the whole path through a real container: jason reports a
  # candidate, the host recomputes its key with Compatibility.BuildCacheKey
  # (the same function the worker used) and promotes it into the slug dir,
  # and the mount the container actually saw was readonly throughout.
  test "promotes jason's own build cache candidate before ingest, over a read-only mount" do
    tmp_cache =
      Path.join(System.tmp_dir!(), "ncc-build-cache-it-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:portal, Portal.Builder, [])

    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.put(previous, :build_cache, tmp_cache)
    )

    on_exit(fn ->
      Application.put_env(:portal, Portal.Builder, previous)
      File.rm_rf(tmp_cache)
    end)

    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.4",
        source: :hex_owner,
        status: :accepted
      })

    image_digest = Builder.image_digest(Builder.docker_image())

    args = %{
      "package" => "jason",
      "version" => "1.4.4",
      "image_digest" => image_digest,
      "scan_request_id" => request.id
    }

    job = %Oban.Job{args: args, attempt: 1, max_attempts: 3}

    assert :ok = Build.perform(job)

    ingest_job =
      all_enqueued(worker: Ingest) |> Enum.find(&(&1.args["scan_request_id"] == request.id))

    assert ingest_job, "expected an Ingest job for scan_request #{request.id}"

    run_id = ingest_job.args["run_id"]
    assert is_binary(run_id)

    # Read result.json before Ingest.perform/1 removes the scratch dir below.
    # Promotion already ran inside Build.perform/1, into tmp_cache, which is
    # outside the scratch tree and survives that cleanup.
    assert {:ok, %{result: result}} = Builder.load_run(run_id)
    candidates = get_in(result, ["cache", "candidates"]) || []
    assert candidates != [], "expected jason to report at least one build cache candidate"
    assert Enum.all?(candidates, &(&1["dep"] == "jason"))

    expected_keys =
      candidates
      |> Enum.map(fn c ->
        {:ok, key} =
          BuildCacheKey.key(%{
            elixir: c["elixir"],
            otp: c["otp"],
            target: c["target"],
            dep: c["dep"],
            dep_lock: c["dep_lock"],
            closure: Enum.map(c["closure"] || [], &{&1["name"], &1["lock"]})
          })

        key
      end)
      |> MapSet.new()

    slug_dir = Builder.build_cache_slug_dir(image_digest)
    assert slug_dir, "expected the build cache to be configured for this test"
    assert File.dir?(slug_dir)

    entries = slug_dir |> File.ls!() |> Enum.filter(&hex64?/1)
    assert entries != [], "expected at least one promoted 64-hex entry in #{slug_dir}"

    for entry <- entries do
      assert entry in expected_keys,
             "cache entry #{entry} does not match any candidate's recomputed key"
    end

    # The container is gone (--rm) by now, so the only way to confirm what it
    # saw is to rebuild the same mount list Portal.Builder gave it.
    mount_job = %{run_id: run_id, image_name: Builder.docker_image(), image_digest: image_digest}
    mount_args = Builder.build_docker_args(mount_job, "/work", "/out", "/files")
    mount = Enum.find(mount_args, &String.contains?(&1, "target=/build-cache"))
    assert mount, "expected a /build-cache mount in the container's docker args"
    assert String.ends_with?(mount, "target=/build-cache,readonly")

    # Drain the ingest job so it does not linger for other tests in this file.
    assert :ok = Ingest.perform(%Oban.Job{args: ingest_job.args, attempt: 1, max_attempts: 5})
    Repo.delete!(ingest_job)
  end

  # Isolation spec, section 1: the deploy-time warm fills the cache through
  # trusted code only; a build then mounts it read-only, resolves through its
  # per-run symlink farm, reports its locked Nerves packages and no misses,
  # and so queues no warm.
  @tag timeout: :timer.minutes(90)
  test "a template warm fills the read-only Nerves cache a jason build then reads" do
    root = Builder.nerves_cache()

    assert :ok = Portal.NervesCache.deploy_warm()

    assert {:ok, template} = Portal.NervesCache.template_entries(root)
    assert Enum.any?(template, &String.starts_with?(&1, "nerves_system_x86_64-"))
    assert Enum.any?(template, &String.starts_with?(&1, "nerves_toolchain_"))

    artifacts = Path.join(root, "artifacts")

    installed =
      Enum.filter(
        template,
        &match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(artifacts, &1)))
      )

    assert Enum.any?(installed, &String.starts_with?(&1, "nerves_system_x86_64-"))

    for entry <- installed,
        do: assert(File.regular?(Path.join([artifacts, entry, ".fingerprint"])))

    assert File.ls(Path.join(root, "staging")) in [{:ok, []}, {:error, :enoent}]

    {:ok, request} =
      ScanRequests.create_once(%{
        package_name: "jason",
        version: "1.4.2",
        source: :hex_owner,
        status: :accepted
      })

    image_digest = Builder.image_digest(Builder.docker_image())

    job = %Oban.Job{
      args: %{
        "package" => "jason",
        "version" => "1.4.2",
        "image_digest" => image_digest,
        "scan_request_id" => request.id
      },
      attempt: 1,
      max_attempts: 3
    }

    assert :ok = Build.perform(job)

    ingest_job =
      all_enqueued(worker: Ingest) |> Enum.find(&(&1.args["scan_request_id"] == request.id))

    assert ingest_job
    run_id = ingest_job.args["run_id"]
    assert {:ok, %{result: result}} = Builder.load_run(run_id)

    assert %{"misses" => [], "lock" => [_ | _] = lock} = result["nerves_cache"]
    locked = MapSet.new(lock, &"#{&1["name"]}-#{&1["version"]}")
    assert MapSet.subset?(locked, template)
    assert all_enqueued(worker: WarmNerves) == []

    mount_job = %{run_id: run_id, image_name: Builder.docker_image(), image_digest: image_digest}
    build_args = Builder.build_docker_args(mount_job, "/work", "/out", "/files")

    warm_args =
      Builder.build_docker_args(
        Map.put(mount_job, :mode, "warm_nerves"),
        "/work",
        "/out",
        "/files"
      )

    assert "type=bind,source=#{root},target=/nerves-cache,readonly" in build_args
    assert "type=bind,source=#{root},target=/nerves-cache" in warm_args
    refute Enum.any?(build_args ++ warm_args, &String.contains?(&1, "/home/nerves/.nerves"))

    assert :ok = Ingest.perform(%Oban.Job{args: ingest_job.args, attempt: 1, max_attempts: 5})
    Repo.delete!(ingest_job)
  end

  defp hex64?(name), do: String.match?(name, ~r/\A[0-9a-f]{64}\z/)

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
        "image_digest" => Builder.image_digest(Builder.docker_image()),
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
    match?(
      {_, 0},
      System.cmd("docker", ["image", "inspect", Builder.docker_image()], stderr_to_stdout: true)
    )
  end
end
