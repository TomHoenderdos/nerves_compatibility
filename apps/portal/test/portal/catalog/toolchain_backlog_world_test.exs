defmodule Portal.Catalog.ToolchainBacklogWorldTest do
  # World builds (`Compatibility.Worlds`, phase 1a): a version of a top
  # package with a with build that passed or was skipped is built once more in
  # each enabled world, while the `world_variants_enabled` setting is on.
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package}
  alias Portal.Workers.{ToolchainBuild, ToolchainSweep}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @lock %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}}

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      previous
      |> Keyword.merge(
        builder_version: 1,
        max_per_run: 8,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}],
        backfill_top_versions_packages: 0,
        backfill_packages: 0
      )
      |> Keyword.drop([:worlds, :world_top_packages, :world_share])
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    :ok
  end

  defp enable_worlds!, do: {:ok, _} = Portal.Settings.save(%{world_variants_enabled: true})

  defp put_toolchains(overrides) do
    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(Application.fetch_env!(:portal, Portal.Toolchains), overrides)
    )
  end

  defp run!(name, version, recent) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version, "native_components" => @pure},
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          run_id: "run-#{name}-#{version}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!(),
          package: name,
          version: version
        }
      )

    package!(name)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  defp package!(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)

  # A marked row (rule 1, config reads recorded) with a recorded optional-deps
  # report, so nothing else reopens it.
  defp row!(name, version, status, opts \\ []) do
    row =
      Portal.Catalog.ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: package!(name).id,
        version: version,
        toolchain: "1.19/28",
        builder_version: 1,
        variant: Keyword.get(opts, :variant, :with),
        config_variant: "default",
        status: status,
        reason: Keyword.get(opts, :reason),
        deps_lock: Keyword.get(opts, :deps_lock, @lock),
        optional_deps: %{"added" => []},
        compile_env_rule: 1,
        compile_env: [],
        run_id: "tc-#{name}-#{version}-#{System.unique_integer([:positive])}",
        finished_at: DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days_ago, 30) * @day)
      })
      |> Ash.create!(domain: Catalog)

    if Keyword.get(opts, :revoked, false),
      do: row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog),
      else: row
  end

  defp worlds(rows),
    do: for(%{variant: :world_phx} = r <- rows, do: {r.package, r.version, r.reopen})

  defp backlog(limit \\ 50), do: Catalog.toolchain_backlog("1.19/28", 1, limit, backfill: [])

  test "the setting is off by default, and off proposes no world build" do
    refute Portal.Settings.get().world_variants_enabled
    assert Portal.Toolchains.world_variants() == []

    run!("phoenix", "1.8.16", 1_000)
    row!("phoenix", "1.8.16", :pass)

    assert worlds(backlog()) == []
  end

  describe "with world builds enabled" do
    setup do
      enable_worlds!()
      :ok
    end

    test "a with pass or skip wants its world build; other statuses and a revoked row do not" do
      for {name, status, opts} <- [
            {"passed", :pass, []},
            {"skipped", :skipped, [reason: "calls natively built dependency"]},
            {"errored", :error, []},
            {"failed", :fail, []},
            {"revoked", :pass, [revoked: true]},
            {"unlocked", :pass, [deps_lock: nil]}
          ] do
        run!(name, "1.0.0", 100)
        row!(name, "1.0.0", status, opts)
      end

      assert Portal.Toolchains.world_variants() == [:world_phx]

      assert Enum.sort(worlds(backlog())) == [
               {"passed", "1.0.0", false},
               {"skipped", "1.0.0", false}
             ]
    end

    test "a without row alone wants nothing" do
      run!("solo", "1.0.0", 100)
      row!("solo", "1.0.0", :pass, variant: :without)
      assert worlds(backlog()) == []
    end

    test "a live world row removes the candidate, a day-old world error brings it back" do
      run!("phoenix", "1.8.16", 1_000)
      row!("phoenix", "1.8.16", :pass)

      world =
        row!("phoenix", "1.8.16", :skipped,
          variant: :world_phx,
          reason: "same closure as the with build"
        )

      assert worlds(backlog()) == []

      Portal.Repo.query!("DELETE FROM catalog_toolchain_builds WHERE id = $1::uuid", [
        Ecto.UUID.dump!(world.id)
      ])

      row!("phoenix", "1.8.16", :error, variant: :world_phx, days_ago: 2)
      assert worlds(backlog()) == [{"phoenix", "1.8.16", false}]
    end

    test "only the world_top_packages most downloaded packages; nil wants every one" do
      for {name, recent} <- [{"big", 9_000}, {"mid", 500}, {"small", 3}] do
        run!(name, "1.0.0", recent)
        row!(name, "1.0.0", :pass)
      end

      put_toolchains(world_top_packages: 2)
      assert backlog() |> worlds() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["big", "mid"]

      put_toolchains(world_top_packages: nil)

      assert backlog() |> worlds() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["big", "mid", "small"]
    end

    test "a configured worlds list without phx proposes none" do
      run!("phoenix", "1.8.16", 1_000)
      row!("phoenix", "1.8.16", :pass)

      put_toolchains(worlds: [])
      assert worlds(backlog()) == []
    end

    test "world candidates rank after new defaults and keep their own limit" do
      run!("phoenix", "1.8.16", 9_000)
      row!("phoenix", "1.8.16", :pass)
      for i <- 1..4, do: run!("new#{i}", "1.0.0", 10 + i)

      rows = backlog(2)

      assert worlds(rows) == [{"phoenix", "1.8.16", false}]
      assert length(for(%{variant: :with} <- rows, do: 1)) == 2
      assert List.last(rows).variant == :world_phx
    end

    test "the sweep gives world builds their share of the cap at priority 3" do
      for i <- 1..6 do
        run!("top#{i}", "1.0.0", 9_000 - i)
        row!("top#{i}", "1.0.0", :pass)
      end

      for i <- 1..10, do: run!("new#{i}", "1.0.0", 100 - i)

      # max_per_run 8: a quarter (2) to world builds, the rest to the
      # refresh reserve and the new defaults, which fill it.
      assert :ok = perform_job(ToolchainSweep, %{"force" => true})

      jobs = all_enqueued(worker: ToolchainBuild)
      world_jobs = Enum.filter(jobs, &(&1.args["variant"] == "world_phx"))

      assert length(jobs) == 8
      assert length(world_jobs) == 2
      assert Enum.all?(world_jobs, &(&1.priority == 3))
      assert Enum.all?(jobs -- world_jobs, &(&1.priority == 0))
    end

    test "with no new defaults, world builds take the whole cap" do
      for i <- 1..10 do
        run!("top#{i}", "1.0.0", 9_000 - i)
        row!("top#{i}", "1.0.0", :pass)
      end

      assert :ok = perform_job(ToolchainSweep, %{"force" => true})

      jobs = all_enqueued(worker: ToolchainBuild)
      assert length(jobs) == 8
      assert Enum.all?(jobs, &(&1.args["variant"] == "world_phx"))
    end

    test "a share world builds do not fill goes back to the defaults" do
      run!("top", "1.0.0", 9_000)
      row!("top", "1.0.0", :pass)
      for i <- 1..10, do: run!("new#{i}", "1.0.0", 100 - i)

      assert :ok = perform_job(ToolchainSweep, %{"force" => true})

      jobs = all_enqueued(worker: ToolchainBuild)
      assert length(jobs) == 8
      assert length(Enum.filter(jobs, &(&1.args["variant"] == "world_phx"))) == 1
    end
  end

  test "world counts: rows by status per toolchain, the same-closure skips, and the candidates" do
    for i <- 1..3 do
      run!("top#{i}", "1.0.0", 9_000 - i)
      row!("top#{i}", "1.0.0", :pass)
    end

    row!("top1", "1.0.0", :pass, variant: :world_phx, deps_lock: %{})
    row!("top2", "1.0.0", :skipped, variant: :world_phx, reason: "same closure as the with build")

    # Off: what turning it on would propose, and no world row in the
    # with/without counts.
    assert %{"1.19/28" => counts} = Catalog.toolchain_world_counts()
    assert %{enabled: false, pass: 1, skipped: 1, same_closure: 1, error: 0, fail: 0} = counts
    assert counts.candidates == 1
    assert %{pass: 3, skipped: 0} = Catalog.toolchain_counts()["1.19/28"]

    enable_worlds!()
    assert %{"1.19/28" => %{enabled: true, candidates: 1}} = Catalog.toolchain_world_counts()
  end

  test "the sweep enqueues no world build while the setting is off" do
    for i <- 1..3 do
      run!("top#{i}", "1.0.0", 9_000 - i)
      row!("top#{i}", "1.0.0", :pass)
    end

    assert :ok = perform_job(ToolchainSweep, %{"force" => true})
    refute Enum.any?(all_enqueued(worker: ToolchainBuild), &(&1.args["variant"] == "world_phx"))
  end
end
