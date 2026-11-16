defmodule Portal.Workers.ClosureDriftTest do
  # Not async: it swaps the `Portal.Toolchains` and worker application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Portal.PrecompiledFixtures

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.Package
  alias Portal.Catalog.ToolchainBuild, as: ToolchainRow
  alias Portal.Workers.{ClosureDrift, ToolchainBuild}

  @built "2026-11-10T00:00:00Z"
  @released ~U[2026-11-12 00:00:00Z]

  # Stands in for `Portal.HexRegistry`; the worker runs in the test process.
  defmodule StubRegistry do
    def snapshot(opts) do
      send(self(), {:asked_registry, opts})
      Process.get(:hex_answer, {:ok, []})
    end
  end

  setup do
    toolchains = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(toolchains,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}],
        builder_version: 1
      )
    )

    drift = Application.get_env(:portal, ClosureDrift, [])
    Application.put_env(:portal, :hex_registry_source, StubRegistry)

    on_exit(fn ->
      Application.put_env(:portal, Portal.Toolchains, toolchains)
      Application.put_env(:portal, ClosureDrift, drift)
      Application.delete_env(:portal, :hex_registry_source)
    end)

    :ok
  end

  defp registry(packages) do
    entries =
      for {name, versions} <- packages do
        %{
          name: name,
          latest_version: List.last(versions),
          updated_at: @released,
          versions: versions,
          retired: []
        }
      end

    Process.put(:hex_answer, {:ok, entries})
  end

  defp release(version, deps) do
    deps =
      for {package, requirement} <- deps,
          do: %{package: package, requirement: requirement, optional: false, repository: "hexpm"}

    %{version: version, retired?: false, outer_checksum: nil, deps: deps}
  end

  defp hex_releases(releases), do: Process.put({Portal.Test.FakeHexDeps, :releases}, releases)

  defp lock(certifi), do: %{"certifi" => %{"version" => certifi, "checksum" => "c-#{certifi}"}}

  defp built!(name, version, certifi, opts \\ []) do
    ingest_toolchain_build(name, version, [deps_lock: lock(certifi), finished_at: @built] ++ opts)
  end

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # `name` 0.3.0 and 0.4.0 on hex, each `certifi ~> 2.18`; certifi 2.19.0 out.
  defp drifted_world(names) do
    registry([{"certifi", ["2.18.0", "2.19.0"]} | Enum.map(names, &{&1, ["0.3.0", "0.4.0"]})])

    hex_releases(
      Map.new(names, fn name ->
        {name,
         [release("0.3.0", [{"certifi", "~> 2.18"}]), release("0.4.0", [{"certifi", "~> 2.18"}])]}
      end)
      |> Map.put("certifi", [release("2.18.0", []), release("2.19.0", [])])
    )
  end

  defp name, do: "drift_#{System.unique_integer([:positive])}"

  test "queues a low-priority rebuild of a drifted build of the newest release, saying why" do
    name = name()
    drifted_world([name])
    built!(name, "0.4.0", "2.18.0")

    assert {:ok, %{enqueued: 1, drifted: 1}} = ClosureDrift.run()

    assert [job] = all_enqueued(worker: ToolchainBuild)
    assert job.priority == 3
    assert job.queue == "toolchain"

    assert job.args == %{
             "package" => name,
             "version" => "0.4.0",
             "toolchain" => "1.19/28",
             "image" => "ncc-worker:elixir-1.19-otp-28",
             "builder_version" => 1,
             "variant" => "with",
             "config_variant" => "default",
             "reason" => "closure_drift",
             "drift" => [%{"dep" => "certifi", "from" => "2.18.0", "to" => "2.19.0"}]
           }
  end

  test "an older release and a build at the newest lock are left alone" do
    [old, current] = [name(), name()]
    drifted_world([old, current])
    built!(old, "0.3.0", "2.18.0")
    built!(current, "0.4.0", "2.19.0")

    assert {:ok, %{enqueued: 0, drifted: 0}} = ClosureDrift.run()
    assert all_enqueued(worker: ToolchainBuild) == []
  end

  test "a run queues at most its cap, most downloaded package first" do
    [obscure, popular] = [name(), name()]
    drifted_world([obscure, popular])
    built!(obscure, "0.4.0", "2.18.0")
    built!(popular, "0.4.0", "2.18.0")
    downloads!(obscure, 10)
    downloads!(popular, 1_000_000)
    Application.put_env(:portal, ClosureDrift, enabled: true, max_per_run: 1)

    assert {:ok, %{enqueued: 1}} = ClosureDrift.run()
    assert [%{args: %{"package" => ^popular}}] = all_enqueued(worker: ToolchainBuild)
  end

  test "a build already queued is not queued again" do
    name = name()
    drifted_world([name])
    built!(name, "0.4.0", "2.18.0")

    assert {:ok, %{enqueued: 1}} = ClosureDrift.run()
    assert {:ok, %{enqueued: 0, pending: 1}} = ClosureDrift.run()
    assert [_job] = all_enqueued(worker: ToolchainBuild)
  end

  test "keeps the build it is about to replace, and the manifest still lists it once" do
    name = name()
    drifted_world([name])
    built!(name, "0.4.0", "2.18.0")

    assert {:ok, %{enqueued: 1}} = ClosureDrift.run()

    row =
      ToolchainRow
      |> Ash.Query.filter(package.name == ^name)
      |> Ash.read_one!(domain: Catalog)

    assert [%{"deps_lock" => kept}] = row.earlier_builds
    assert kept == lock("2.18.0")

    %{"versions" => %{"0.4.0" => %{"builds" => builds}}} = Catalog.precompiled_manifest_v2(name)
    assert [%{"build" => %{"deps" => deps}}] = builds
    assert deps == lock("2.18.0")
  end

  test "a dry run queues and writes nothing" do
    name = name()
    drifted_world([name])
    built!(name, "0.4.0", "2.18.0")

    assert {:ok, %{drifted: 1, enqueued: 0}} = ClosureDrift.run(dry_run: true)
    assert all_enqueued(worker: ToolchainBuild) == []

    assert [%{earlier_builds: nil}] =
             ToolchainRow
             |> Ash.Query.filter(package.name == ^name)
             |> Ash.read!(domain: Catalog)
  end

  test "the schedule does nothing while switched off; a manual run still checks" do
    Application.put_env(:portal, ClosureDrift, enabled: false)
    registry([])

    assert :ok = perform_job(ClosureDrift, %{})
    refute_received {:asked_registry, _opts}

    assert {:ok, _summary} = perform_job(ClosureDrift, %{"manual" => true})
    assert_received {:asked_registry, [all_versions: true]}
  end

  test "a registry outage fails the run" do
    Process.put(:hex_answer, {:error, :hex_registry_unavailable})
    assert {:error, :hex_registry_unavailable} = perform_job(ClosureDrift, %{"manual" => true})
  end
end
