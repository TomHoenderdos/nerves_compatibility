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

      {:ok, _} =
        Portal.ScanRequests.create_once(%{package_name: "queued_pkg", source: :admin_manual})

      assert :ok = perform_job(Backfill, %{package: "queued_pkg", source: "catalog_seed"})

      assert %{packages: packages} = Portal.Catalog.latest_by_pkg_json("queued_pkg")
      refute Map.has_key?(packages, "queued_pkg")
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

    test "the flag off keeps today's behaviour" do
      Application.put_env(:portal, :queue_filter, enabled: false)
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})
      assert build_priority("tiny_pure") == 9
    end
  end
end
