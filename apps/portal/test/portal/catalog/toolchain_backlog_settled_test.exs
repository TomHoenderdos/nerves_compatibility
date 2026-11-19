defmodule Portal.Catalog.ToolchainBacklogSettledTest do
  # The guard: no tier of `Catalog.toolchain_backlog/3` (new defaults, `with`
  # and `without`, registry and Hex-latest nominations, the version backfill,
  # named config variants, world builds) ever selects an identity whose row
  # is settled at the current judge revision and builder_version, however
  # old the row is. Settled: a `pass`, `skipped` or `fail` row that no
  # documented reopen or refresh case applies to, or any revoked row but one
  # marked for its withheld closure that has not been rebuilt since.
  #
  # The documented cases, each tested where it is defined, are exactly what
  # these rows are built to avoid: a pass that does not record its config
  # reads (refresh, `toolchain_backlog_r5_test.exs`), dropped its optional
  # dependencies for a transient reason, or has transient attempts; a skip
  # for priv files, under rule 1 for a reason rule 2 dropped
  # (`toolchain_backlog_rule2_test.exs`), or below the newest judge revision
  # (`toolchain_backlog_judge_revision_test.exs`); a compile that a signal
  # killed (`toolchain_sweep_test.exs`); an error.
  #
  # Production, 2026-11-19: about 10,900 `fail` rows ("compile failed ...
  # exited with code 1") came back every week as new defaults at priority 0,
  # and 94 skipped rows revoked for their withheld closure, already rebuilt
  # once, came back every week too.
  #
  # Not async: swaps the `Portal.Toolchains` application env, and drops the
  # legacy identity index inside the sandbox transaction.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  import Ecto.Query, only: [from: 2]
  import Portal.PrecompiledFixtures

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}
  alias Portal.Repo

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @judge 30
  @lv4 ~w(debug_attributes debug_heex_annotations enable_expensive_runtime_checks root_tag_attribute)
  @jason %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}}
  @compile_failed "compile failed: host compile failed: mix compile exited with code 1"

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      previous
      |> Keyword.merge(
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}],
        backfill_top_versions_packages: 0,
        backfill_packages: 0
      )
      |> Keyword.drop([:config_variants, :worlds, :world_top_packages, :world_share])
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)

    drop_legacy_identity_index!()
    {:ok, _} = Portal.Settings.save(%{world_variants_enabled: true})
    :ok
  end

  # How each identity the backlog wants is settled: a row's status, and
  # whether it is revoked (`:plain`), revoked for its withheld closure and
  # rebuilt since (`:withheld_rebuilt`), or neither.
  @settlers [
    {:pass, nil},
    {:skipped, nil},
    {:fail, nil},
    {:pass, :plain},
    {:skipped, :plain},
    {:fail, :plain},
    {:skipped, :withheld_rebuilt},
    {:fail, :withheld_rebuilt}
  ]

  for {status, revoked} <- @settlers do
    test "no tier selects an identity settled as #{status}, revoked #{inspect(revoked)}" do
      backfill = scenario!()
      wanted = backlog(backfill)

      # Every tier has something to propose before anything is settled, so
      # the empty backlog below is not empty by accident.
      assert Enum.any?(wanted, &(&1.variant == :without))
      assert Enum.any?(wanted, &(&1.config_variant != "default"))
      assert Enum.any?(wanted, &(&1.variant in Portal.Toolchains.world_variants()))
      assert Enum.any?(wanted, & &1.backfill)
      assert Enum.any?(wanted, &(&1.package == "registry"))
      assert Enum.any?(wanted, &(&1.package == "latest" and &1.version == "1.1.0"))
      assert Enum.any?(wanted, &(&1.package == "host"))

      for identity <- wanted, do: settle!(identity, unquote(status), unquote(revoked))

      assert backlog(backfill) == []
      assert %{"1.19/28" => %{backlog: 0}} = Catalog.toolchain_counts()
      assert Catalog.toolchain_backlog_to_rank(100, 100) == []

      assert :ok = perform_job(Portal.Workers.ToolchainSweep, %{"force" => true})
      assert all_enqueued(worker: Portal.Workers.ToolchainBuild) == []
    end
  end

  # One package per tier, with the settled parent rows the dependent tiers
  # need (a `with` pass that added an optional dependency, one that read
  # LiveView config keys, one with a lock a world can add to). Returns the
  # version backfill to pass.
  defp scenario! do
    run!("host", "1.0.0")
    registry_run!("registry", "1.0.0")

    run!("latest", "1.0.0")
    hex_latest!("latest", "1.1.0")

    run!("old", "2.0.0")

    run!("opt", "1.0.0")
    parent!("opt", optional_deps: %{"added" => ["telemetry"]})

    run!("lv", "1.0.0")
    parent!("lv", compile_env: lv_env(@lv4))

    run!("world", "1.0.0")
    downloads!("world", 1_000)
    parent!("world", deps_lock: @jason)

    [{"old", "1.0.0"}]
  end

  defp backlog(backfill),
    do: Catalog.toolchain_backlog("1.19/28", 1, 1_000, backfill: backfill)

  defp parent!(name, opts) do
    row!(name, "1.0.0", :with, "default", :pass, opts)
  end

  defp settle!(identity, status, revoked) do
    %{package: name, version: version, variant: variant, config_variant: config_variant} =
      identity

    opts =
      case {status, revoked} do
        {:fail, _} -> [reason: @compile_failed, judge_revision: nil]
        {:skipped, _} -> [reason: "calls natively built dependency"]
        _ -> []
      end

    # A withheld-closure mark sits only on a row that records no config
    # reads (`Catalog.mark_withheld_revoked/2`).
    opts = if revoked == :withheld_rebuilt, do: [compile_env: nil] ++ opts, else: opts
    row = row!(name, version, variant, config_variant, status, opts)

    case revoked do
      nil ->
        row

      :plain ->
        row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)

      :withheld_rebuilt ->
        row
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update!(domain: Catalog)
        |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
        |> Ash.update!(domain: Catalog)

        # Revoked a day before the build the row holds now.
        Repo.query!(
          "UPDATE catalog_toolchain_builds SET revoked_at = $2 WHERE id = $1",
          [Ecto.UUID.dump!(row.id), DateTime.to_naive(ago(31 * @day))]
        )
    end
  end

  # A row nothing reopens: rule 2 at the current judge revision, config
  # reads recorded by its own run, an optional-deps report with nothing
  # added and no transient reason, no attempt since its build, a recorded
  # lock that names no withheld package, built a month ago (past every
  # time-based window). `compile_env: nil` drops the config reads.
  defp row!(name, version, variant, config_variant, status, opts) do
    compile_env = Keyword.get(opts, :compile_env, [])

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package!(name).id,
      version: version,
      toolchain: "1.19/28",
      builder_version: 1,
      variant: variant,
      config_variant: config_variant,
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: Keyword.get(opts, :deps_lock, %{}),
      optional_deps: Keyword.get(opts, :optional_deps, %{"added" => []}),
      compile_env_rule: if(compile_env, do: 1),
      compile_env: compile_env,
      portability_rule: 2,
      judge_revision: Keyword.get(opts, :judge_revision, @judge),
      transient_attempts: 0,
      run_id: "tc-#{name}-#{version}-#{variant}-#{config_variant}",
      finished_at: ago(30 * @day)
    })
    |> Ash.create!(domain: Catalog)
  end

  # The `compile_env` of a build that read each of `keys` of
  # `:phoenix_live_view`, all unset.
  defp lv_env(keys) do
    unset =
      :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

    for key <- keys, do: %{"app" => "phoenix_live_view", "path" => [key], "value" => unset}
  end

  defp run!(name, version), do: ingest!(name, version, "host", @pure, "sha256:x")

  # A bulk-intake registry assessment, as `Portal.Catalog.RegistryAssessment`
  # records it.
  defp registry_run!(name, version) do
    ingest!(
      name,
      version,
      "registry_deps",
      %{"compatibility_basis" => "registry_deps"},
      Portal.Catalog.RegistryAssessment.image_digest()
    )
  end

  defp ingest!(name, version, system, native, image_digest) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version, "native_components" => native},
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => %{system => %{"status" => "pass"}}
        },
        %{
          run_id: "run-#{name}-#{version}-#{System.unique_integer([:positive])}",
          image_digest: image_digest,
          files_dir: System.tmp_dir!(),
          package: name,
          version: version
        }
      )

    :ok
  end

  defp package!(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)

  defp downloads!(name, recent) do
    package!(name)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  defp hex_latest!(name, version) do
    {1, _} =
      Repo.update_all(
        from(p in "catalog_packages", where: p.name == ^name),
        set: [hex_latest_version: version]
      )

    :ok
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
end
