defmodule Portal.Workers.ReleaseFastPathTest do
  # Not async: it swaps the `Portal.Toolchains` and worker application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Portal.PrecompiledFixtures

  alias Portal.Workers.{ReleaseFastPath, ToolchainBuild, ToolchainSweep}

  @built "2026-11-10T00:00:00Z"
  @now ~U[2026-11-21 12:00:00Z]

  defmodule StubRegistry do
    def snapshot(_opts), do: Process.get(:hex_answer, {:ok, []})
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

    fast_path = Application.get_env(:portal, ReleaseFastPath, [])
    Application.put_env(:portal, ReleaseFastPath, enabled: true, min_dependents: 2)
    Application.put_env(:portal, :hex_registry_source, StubRegistry)

    on_exit(fn ->
      Application.put_env(:portal, Portal.Toolchains, toolchains)
      Application.put_env(:portal, ReleaseFastPath, fast_path)
      Application.delete_env(:portal, :hex_registry_source)
    end)

    :ok
  end

  defp entry(name, versions, updated_at) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: updated_at,
      versions: versions,
      retired: []
    }
  end

  defp release(version, deps) do
    deps =
      for {package, requirement} <- deps,
          do: %{package: package, requirement: requirement, optional: false, repository: "hexpm"}

    %{version: version, retired?: false, outer_checksum: nil, deps: deps}
  end

  defp locking!(name, dep, version) do
    ingest_toolchain_build(name, "0.4.0",
      deps_lock: %{dep => %{"version" => version, "checksum" => "c-#{version}"}},
      finished_at: @built
    )
  end

  defp name, do: "fast_#{System.unique_integer([:positive])}"

  describe "offer/2" do
    test "offers a release that changed in the window and that enough dependents lock behind" do
      [a, b, c] = [name(), name(), name()]
      locking!(a, "popular", "1.0.0")
      locking!(b, "popular", "1.0.0")
      locking!(c, "lonely", "1.0.0")
      locking!(name(), "stale", "1.0.0")
      locking!(name(), "stale", "1.0.0")

      registry = [
        entry("popular", ["1.0.0", "1.1.0"], DateTime.add(@now, -1800, :second)),
        entry("lonely", ["1.0.0", "1.1.0"], DateTime.add(@now, -1800, :second)),
        entry("stale", ["1.0.0", "1.1.0"], DateTime.add(@now, -5 * 3600, :second))
      ]

      assert ReleaseFastPath.offer(registry, now: @now) == 1

      assert [%{args: %{"package" => "popular", "version" => "1.1.0"}}] =
               all_enqueued(worker: ReleaseFastPath)

      # The same release once.
      assert ReleaseFastPath.offer(registry, now: @now) == 0
    end

    test "a release the dependents already lock is not offered" do
      locking!(name(), "popular", "1.1.0")
      locking!(name(), "popular", "1.1.0")

      registry = [entry("popular", ["1.0.0", "1.1.0"], @now)]

      assert ReleaseFastPath.offer(registry, now: @now) == 0
    end

    test "a prerelease is no release to rebuild for" do
      locking!(name(), "popular", "1.0.0")
      locking!(name(), "popular", "1.0.0")

      assert ReleaseFastPath.offer([entry("popular", ["1.0.0", "1.1.0-rc.1"], @now)], now: @now) ==
               0
    end

    test "offers nothing while switched off" do
      Application.put_env(:portal, ReleaseFastPath, enabled: false, min_dependents: 2)
      locking!(name(), "popular", "1.0.0")
      locking!(name(), "popular", "1.0.0")

      assert ReleaseFastPath.offer([entry("popular", ["1.0.0", "1.1.0"], @now)], now: @now) == 0
    end
  end

  describe "perform/1" do
    test "rebuilds the builds that lock the package ahead of the daily drift, and forces a sweep" do
      [dependent, other] = [name(), name()]
      locking!(dependent, "certifi", "2.18.0")
      locking!(other, "jason", "1.0.0")

      Process.put(
        :hex_answer,
        {:ok,
         [
           entry("certifi", ["2.18.0", "2.19.0"], ~U[2026-11-12 00:00:00Z]),
           entry("jason", ["1.0.0", "1.1.0"], ~U[2026-11-12 00:00:00Z]),
           entry(dependent, ["0.4.0"], ~U[2026-11-01 00:00:00Z]),
           entry(other, ["0.4.0"], ~U[2026-11-01 00:00:00Z])
         ]}
      )

      Process.put(
        {Portal.Test.FakeHexDeps, :releases},
        %{
          dependent => [release("0.4.0", [{"certifi", "~> 2.18"}])],
          other => [release("0.4.0", [{"jason", "~> 1.0"}])],
          "certifi" => [release("2.18.0", []), release("2.19.0", [])],
          "jason" => [release("1.0.0", []), release("1.1.0", [])]
        }
      )

      assert {:ok, %{enqueued: 1}} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert [job] = all_enqueued(worker: ToolchainBuild)
      assert job.priority == 1

      assert %{
               "package" => ^dependent,
               "reason" => "release_fast_path",
               "drift" => [%{"dep" => "certifi", "to" => "2.19.0"}]
             } = job.args

      assert [%{args: %{"force" => true}}] = all_enqueued(worker: ToolchainSweep)
    end

    test "does nothing while switched off" do
      Application.put_env(:portal, ReleaseFastPath, enabled: false)

      assert {:cancel, _} =
               perform_job(ReleaseFastPath, %{"package" => "certifi", "version" => "2.19.0"})

      assert all_enqueued(worker: ToolchainBuild) == []
    end
  end
end
