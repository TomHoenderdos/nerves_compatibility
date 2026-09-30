defmodule Portal.Workers.BackfillTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query

  alias Portal.Workers.Backfill
  alias Portal.Workers.Build

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "9.9.9"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)
    :ok
  end

  # Oban stores the worker without the `Elixir.` prefix that `to_string/1` on a
  # module adds, so `inspect/1` is the form that actually matches the column.
  defp build_priority(package) do
    Portal.Repo.one!(
      from(j in Oban.Job,
        where: j.worker == ^inspect(Build),
        where: fragment("?->>'package'", j.args) == ^package,
        select: j.priority
      )
    )
  end

  describe "perform/1 source handling" do
    test "defaults to backfill when no source is given" do
      assert :ok = perform_job(Backfill, %{package: "sweep_pkg"})
      assert build_priority("sweep_pkg") == 9
    end

    # The split between these two numbers is load-bearing. Seeding the whole
    # registry inserts tens of thousands of rows; if a new release of a package
    # we already display shared their priority it would tie and lose on
    # insertion order, waiting months behind packages nobody has asked for.
    test "update_check outranks catalog_seed" do
      assert :ok = perform_job(Backfill, %{package: "fresh_pkg", source: "update_check"})
      assert :ok = perform_job(Backfill, %{package: "new_pkg", source: "catalog_seed"})

      assert build_priority("fresh_pkg") == 7
      assert build_priority("new_pkg") == 9
      assert build_priority("fresh_pkg") < build_priority("new_pkg")
    end

    # A typo must not quietly become the default priority -- that is exactly the
    # silent mis-scheduling the argument exists to prevent.
    test "an unknown source cancels rather than defaulting" do
      assert {:cancel, {:unknown_source, "typo"}} =
               perform_job(Backfill, %{package: "any_pkg", source: "typo"})

      refute_enqueued(worker: Build)
    end
  end

  defmodule StubClosure do
    def classify(package, _version) do
      Process.get({:closure, package}, {:native, {:marker, "elixir_make"}})
    end
  end

  # Simulates the window between `classify?/2`'s open-request check and
  # `record/3`'s `create_once/1` call: an admin request for the same package
  # opens *during* classification, the way a real hex.pm + registry-closure
  # round trip leaves seconds for a human request to land in.
  defmodule RacingClosure do
    def classify(package, _version) do
      {:ok, _request} =
        Portal.ScanRequests.create_once(%{package_name: package, source: :admin_manual})

      :pure
    end
  end

  describe "perform/1 with the queue filter" do
    setup do
      Application.put_env(:portal, :native_closure, StubClosure)
      Application.put_env(:portal, :queue_filter, enabled: true)

      on_exit(fn ->
        Application.delete_env(:portal, :native_closure)
        Application.delete_env(:portal, :queue_filter)
      end)

      :ok
    end

    defp closure(package, answer), do: Process.put({:closure, package}, answer)

    defp request(package) do
      Portal.Repo.one!(
        from(r in "portal_scan_requests",
          where: r.package_name == ^package,
          select: %{status: r.status, run_id: r.run_id}
        )
      )
    end

    defp registry_run_count(package) do
      Portal.Repo.one!(
        from(r in "catalog_runs",
          join: p in "catalog_packages",
          on: p.id == r.package_id,
          where: p.name == ^package and r.image_digest == "registry",
          select: count(r.id)
        )
      )
    end

    # A Docker-built run as `Portal.Workers.Ingest` would record it: a real
    # system, a description and native components from the worker.
    defp docker_run(package, version, status, digest \\ "sha256:abc", opts \\ []) do
      finished_at =
        opts |> Keyword.get(:finished_at, DateTime.utc_now()) |> DateTime.to_iso8601()

      result = %{
        "package" => %{
          "name" => package,
          "version" => version,
          "description" => "A real package",
          "native_components" => %{"nifs" => ["#{package}_nif"]}
        },
        "started_at" => finished_at,
        "finished_at" => finished_at,
        "systems" => %{
          "nerves_system_rpi4" => %{
            "system_version" => "1.26.1",
            "status" => status,
            "duration_sec" => 10.0,
            "log_tail" => "built"
          }
        }
      }

      {:ok, run} =
        Portal.Catalog.Ingestion.ingest(result, %{
          run_id: "#{package}-docker-#{version}",
          image_digest: digest,
          files_dir: System.tmp_dir!(),
          scan_request_id: nil
        })

      run
    end

    defp request_count(package) do
      Portal.Repo.one!(
        from(r in "portal_scan_requests",
          where: r.package_name == ^package,
          select: count(r.id)
        )
      )
    end

    test "a pure seed package is recorded without a build" do
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})

      refute_enqueued(worker: Build)
      assert %{status: "built", run_id: run_id} = request("tiny_pure")
      assert run_id

      %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
      assert package.native_components["compatibility_basis"] == "registry_deps"
    end

    test "a native seed package takes the build path" do
      closure("nif_pkg", {:native, {:marker, "rustler"}})

      assert :ok = perform_job(Backfill, %{package: "nif_pkg", source: "catalog_seed"})
      assert build_priority("nif_pkg") == 9
    end

    test "the legacy backfill source is filtered too" do
      closure("tiny_pure", :pure)
      assert :ok = perform_job(Backfill, %{package: "tiny_pure"})
      refute_enqueued(worker: Build)
    end

    test "a registry outage retries and never builds" do
      closure("tiny_pure", {:error, :hex_registry_unavailable})

      assert {:error, :hex_registry_unavailable} =
               perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})

      refute_enqueued(worker: Build)
    end

    test "an already open request is left to its build" do
      closure("queued_pkg", :pure)

      {:ok, existing} =
        Portal.ScanRequests.create_once(%{package_name: "queued_pkg", source: :admin_manual})

      assert :ok = perform_job(Backfill, %{package: "queued_pkg", source: "catalog_seed"})

      assert %{packages: packages} = Portal.Catalog.latest_by_pkg_json("queued_pkg")
      refute Map.has_key?(packages, "queued_pkg")

      assert request_count("queued_pkg") == 1
      assert %{status: status, run_id: nil} = request("queued_pkg")
      assert status == to_string(existing.status)
    end

    # `classify?/2` finds no open request, but the hex.pm + registry-closure
    # round trip in `classify/2` takes real time, and an admin or anonymous
    # request can open in that window. `record/3` must not attach the registry
    # run to it or stomp its status -- that would silently close a queued
    # admin build (or skip anonymous review) that this job knows nothing about.
    test "a request that opens mid-classification wins the race" do
      Application.put_env(:portal, :native_closure, RacingClosure)

      assert :ok = perform_job(Backfill, %{package: "raced_pkg", source: "catalog_seed"})

      assert request_count("raced_pkg") == 1
      assert %{status: "queued", run_id: nil} = request("raced_pkg")

      assert %{packages: packages} = Portal.Catalog.latest_by_pkg_json("raced_pkg")
      refute Map.has_key?(packages, "raced_pkg")
    end

    test "update_check re-classifies a registry-assessed package" do
      {:ok, _} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.0.0", nil)
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "update_check"})

      refute_enqueued(worker: Build)

      %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
      assert package.latest_version == "9.9.9"
    end

    test "update_check on a registry-assessed package that turned native builds it" do
      {:ok, _} = Portal.Catalog.RegistryAssessment.record("grew_nif", "1.0.0", nil)
      closure("grew_nif", {:native, {:marker, "rustler_precompiled"}})

      assert :ok = perform_job(Backfill, %{package: "grew_nif", source: "update_check"})
      assert build_priority("grew_nif") == 7
    end

    test "update_check on a docker-built package never classifies" do
      closure("real_pkg", :pure)

      package =
        Ash.create!(Portal.Catalog.Package, %{name: "real_pkg", latest_version: "1.0.0"},
          action: :create,
          domain: Portal.Catalog
        )

      Ash.create!(
        Portal.Catalog.Run,
        %{
          run_id: "real_pkg-docker",
          package_id: package.id,
          version_tested: "1.0.0",
          image_digest: "sha256:abc",
          overall_status: :pass,
          finished_at: DateTime.utc_now()
        },
        action: :create,
        domain: Portal.Catalog
      )

      assert :ok = perform_job(Backfill, %{package: "real_pkg", source: "update_check"})
      assert build_priority("real_pkg") == 7
    end

    test "a backfill of a docker-built package builds and writes no registry run" do
      closure("tracked_pkg", :pure)
      docker_run("tracked_pkg", "1.0.0", "pass")

      assert :ok = perform_job(Backfill, %{package: "tracked_pkg", source: "backfill"})

      assert build_priority("tracked_pkg") == 9
      assert registry_run_count("tracked_pkg") == 0
    end

    test "a catalog_seed of a docker-built package builds and writes no registry run" do
      closure("tracked_pkg", :pure)
      docker_run("tracked_pkg", "1.0.0", "pass")

      assert :ok = perform_job(Backfill, %{package: "tracked_pkg", source: "catalog_seed"})

      assert build_priority("tracked_pkg") == 9
      assert registry_run_count("tracked_pkg") == 0
    end

    # The failure the eligibility check exists for: a pure verdict recorded on
    # top of a real failing build would flip the package green and blank the
    # description the real run wrote.
    test "a failing docker-built package is not superseded by a bulk sweep" do
      closure("broken_pkg", :pure)
      docker_run("broken_pkg", "1.0.0", "fail")

      for source <- ~w(backfill catalog_seed) do
        assert :ok = perform_job(Backfill, %{package: "broken_pkg", source: source})
      end

      assert registry_run_count("broken_pkg") == 0

      %{packages: %{"broken_pkg" => package}} = Portal.Catalog.latest_by_pkg_json("broken_pkg")
      assert package.description == "A real package"
      assert package.native_components == %{"nifs" => ["broken_pkg_nif"]}
      assert [system] = Map.values(package.systems)
      assert system.system_pkg == "nerves_system_rpi4"
      assert system.status == "fail"
      assert system.run_id == "broken_pkg-docker-1.0.0"
    end

    # Runs imported from before the portal have no digest at all. They are
    # real results, not "never built".
    test "a run with no digest is not treated as never built" do
      closure("legacy_pkg", :pure)
      docker_run("legacy_pkg", "1.0.0", "pass", nil)

      assert :ok = perform_job(Backfill, %{package: "legacy_pkg", source: "catalog_seed"})

      assert build_priority("legacy_pkg") == 9
      assert registry_run_count("legacy_pkg") == 0
    end

    test "a never-built package is still classified" do
      closure("never_built", :pure)

      assert :ok = perform_job(Backfill, %{package: "never_built", source: "backfill"})

      refute_enqueued(worker: Build)
      assert registry_run_count("never_built") == 1
    end

    # End to end: a human-requested real build lands after the registry
    # assessment. From then on the real result is what the catalogue shows,
    # and the package has left the registry path for good.
    test "a real build after a registry assessment wins and ends classification" do
      closure("promoted_pkg", :pure)
      {:ok, _} = Portal.Catalog.RegistryAssessment.record("promoted_pkg", "1.0.0", nil)

      docker_run("promoted_pkg", "1.0.0", "fail", "sha256:abc",
        finished_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      %{packages: %{"promoted_pkg" => package}} =
        Portal.Catalog.latest_by_pkg_json("promoted_pkg")

      assert [system] = Map.values(package.systems)
      assert system.system_pkg == "nerves_system_rpi4"
      assert system.status == "fail"
      assert package.native_components == %{"nifs" => ["promoted_pkg_nif"]}

      assert :ok = perform_job(Backfill, %{package: "promoted_pkg", source: "update_check"})
      assert build_priority("promoted_pkg") == 7
      assert registry_run_count("promoted_pkg") == 1
    end

    test "the flag off keeps today's behaviour" do
      Application.put_env(:portal, :queue_filter, enabled: false)
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})
      assert build_priority("tiny_pure") == 9
    end
  end
end
