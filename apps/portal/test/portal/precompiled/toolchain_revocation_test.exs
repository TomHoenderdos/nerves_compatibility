defmodule Portal.Precompiled.ToolchainRevocationTest do
  # Not async: swaps the `Portal.Toolchains` application env and ingests into
  # the shared catalog.
  use Portal.DataCase, async: false

  require Ash.Query

  import Portal.PrecompiledFixtures

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, SystemResult, ToolchainBuild}
  alias Portal.Precompiled.{Batches, Keys, ToolchainRevocation}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @env [%{"app" => "demo", "key" => "mode", "value" => "x"}]
  @cmd "calls System.cmd/2"
  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(previous,
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    :ok
  end

  defp run!(name, version) do
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

    :ok
  end

  # `marked: true` gives the row the R5 mark: rule 1 next to a `compile_env`.
  defp row!(name, version, status, opts) do
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
    marked? = Keyword.get(opts, :marked, false)

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: version,
      toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
      builder_version: Keyword.get(opts, :builder_version, 1),
      variant: Keyword.get(opts, :variant, :with),
      config_variant: Keyword.get(opts, :config_variant, "default"),
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: %{},
      compile_env_rule: if(marked?, do: 1),
      compile_env: if(marked?, do: @env),
      portability_rule: Keyword.get(opts, :rule),
      rule1_reason: Keyword.get(opts, :rule1_reason),
      run_id: "tc-#{name}-#{version}-#{System.unique_integer([:positive])}",
      finished_at: Keyword.get(opts, :finished_at, ago(30 * @day))
    })
    |> Ash.create!(domain: Catalog)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp seed! do
    run!("phoenix", "1.8.16")
    added = row!("phoenix", "1.8.16", :pass, rule: 2, rule1_reason: @cmd, marked: true)
    run!("jason", "1.4.5")
    plain = row!("jason", "1.4.5", :pass, rule: 2, marked: true)
    run!("old", "1.0.0")
    rule1 = row!("old", "1.0.0", :pass, rule1_reason: @cmd, marked: true)
    %{added: added, plain: plain, rule1: rule1}
  end

  defp reload(%ToolchainBuild{} = row), do: Ash.get!(ToolchainBuild, row.id, domain: Catalog)
  defp reload(%SystemResult{} = row), do: Ash.get!(SystemResult, row.id, domain: Catalog)

  defp backlog_names,
    do: Enum.map(Catalog.toolchain_backlog("1.19/28", 1, 100), & &1.package)

  describe "toolchain builds" do
    test "a dry run lists only builds rule 2 added and writes nothing" do
      %{added: added} = seed!()
      added_id = added.id

      assert {:dry_run,
              [
                %{
                  kind: :toolchain_build,
                  package: "phoenix",
                  version: "1.8.16",
                  toolchain: "1.19/28",
                  variant: "with",
                  config_variant: "default",
                  rule1_reason: @cmd,
                  id: ^added_id
                }
              ]} = ToolchainRevocation.revoke(all: true)

      assert {:dry_run, [_]} = ToolchainRevocation.revoke()
      assert reload(added).revoked_at == nil
      assert ToolchainRevocation.revocations() == []
    end

    test "only the current builder version, a pass and an unrevoked row are revoked" do
      run!("phoenix", "1.8.16")
      row!("phoenix", "1.8.16", :pass, rule: 2, rule1_reason: @cmd, builder_version: 0)
      row!("phoenix", "1.8.16", :skipped, rule: 2, rule1_reason: @cmd, variant: :without)

      assert {:dry_run, []} = ToolchainRevocation.revoke(all: true)
    end

    test "acting needs a filter; it revokes, unserves and is undone by its timestamp" do
      %{plain: plain, rule1: rule1} = seed!()
      # A served rule-2 addition: its file is in the artifact store.
      added = ingest_toolchain_build("served", "1.0.0", portability_rule: 2, rule1_reason: @cmd)

      assert "served" in Catalog.packages_with_precompiled_files()
      assert {:error, :filter_required} = ToolchainRevocation.revoke(dry_run: false)

      assert {:revoked, 1, [%{package: "served", id: added_id}], at} =
               ToolchainRevocation.revoke(dry_run: false, package: "served", version: "1.0.0")

      assert added_id == added.id
      assert %{revoked_at: %DateTime{}, revoked_reason: "rule 2 revoked"} = reload(added)
      assert reload(plain).revoked_at == nil
      assert reload(rule1).revoked_at == nil
      refute "served" in Catalog.packages_with_precompiled_files()
      assert [{^at, 1}] = ToolchainRevocation.revocations()

      assert {:ok, 1} = ToolchainRevocation.undo(at)
      assert %{revoked_at: nil, revoked_reason: nil} = reload(added)
      assert "served" in Catalog.packages_with_precompiled_files()
      assert ToolchainRevocation.revocations() == []
    end

    test "a version needs its package" do
      assert_raise ArgumentError, fn -> ToolchainRevocation.revoke(version: "1.0.0") end
      assert_raise ArgumentError, fn -> ToolchainRevocation.revoke(all: true, limit: 0) end
    end

    test "a revoked row is not rebuilt by the backlog" do
      run!("phoenix", "1.8.16")
      # Unmarked and a month old: a pass the backlog refreshes.
      row!("phoenix", "1.8.16", :pass, rule: 2, rule1_reason: @cmd)
      assert "phoenix" in backlog_names()

      {:revoked, 1, _, _} =
        ToolchainRevocation.revoke(dry_run: false, rule1_prefix: "calls System.cmd/")

      refute "phoenix" in backlog_names()
    end

    test "rule1_prefix narrows by what rule 1 said" do
      seed!()
      run!("shell", "1.0.0")
      row!("shell", "1.0.0", :pass, rule: 2, rule1_reason: "calls os:cmd/1", marked: true)

      assert {:dry_run, [%{package: "shell"}]} =
               ToolchainRevocation.revoke(rule1_prefix: "calls os:cmd/")

      assert {:revoked, 1, [%{package: "phoenix"}], _} =
               ToolchainRevocation.revoke(dry_run: false, rule1_prefix: "calls System.cmd/")
    end

    test "limit caps one call, and the rows returned are exactly the ones revoked" do
      ids =
        for i <- 1..3 do
          run!("p#{i}", "1.0.0")
          row!("p#{i}", "1.0.0", :pass, rule: 2, rule1_reason: "calls os:cmd/1", marked: true).id
        end

      assert {:revoked, 2, rows, _} =
               ToolchainRevocation.revoke(dry_run: false, all: true, limit: 2)

      revoked =
        for id <- ids,
            not is_nil(Ash.get!(ToolchainBuild, id, domain: Catalog).revoked_at),
            do: id

      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(revoked)
      assert Enum.map(rows, & &1.package) == ["p1", "p2"]

      assert {:dry_run, [%{package: "p3", id: left}]} = ToolchainRevocation.revoke(all: true)
      assert [left] == ids -- revoked
    end

    test "acting again revokes nothing more" do
      seed!()
      assert {:revoked, 1, _, at} = ToolchainRevocation.revoke(dry_run: false, all: true)
      assert {:revoked, 0, [], _} = ToolchainRevocation.revoke(dry_run: false, all: true)
      assert {:dry_run, []} = ToolchainRevocation.revoke(all: true)
      assert [{^at, 1}] = ToolchainRevocation.revocations()
    end

    test "Catalog delegates to the tool" do
      seed!()
      assert {:dry_run, [%{package: "phoenix"}]} = Catalog.revoke_toolchain_builds(all: true)
    end
  end

  describe "the signed batch" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      old = Application.get_env(:portal, :precompiled_signing)
      on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
      path = Path.join(dir, "signing.key")
      Keys.write!(path, Keys.generate())
      Application.put_env(:portal, :precompiled_signing, key_path: path)
      :ok
    end

    test "a revocation drops the build from the next batch, an undo puts it back" do
      ingest_toolchain_build("phoenix", "1.8.16", portability_rule: 2, rule1_reason: @cmd)
      before = Catalog.precompiled_fingerprints()["phoenix"]
      {:ok, b1} = Batches.build_and_sign()
      assert Map.has_key?(Batches.manifests_v2(b1), "phoenix")

      {:revoked, 1, _, at} = ToolchainRevocation.revoke(dry_run: false, package: "phoenix")

      assert Catalog.precompiled_fingerprints()["phoenix"] != before
      {:ok, b2} = Batches.build_and_sign()
      refute Map.has_key?(Batches.manifests_v2(b2), "phoenix")

      {:ok, 1} = ToolchainRevocation.undo(at)
      {:ok, b3} = Batches.build_and_sign()
      assert Map.has_key?(Batches.manifests_v2(b3), "phoenix")
    end
  end

  describe "pure_elixir system results" do
    # The fixture's jason 1.4.1 run, its publishing rpi4 result also
    # published as the run's pure_elixir result, judged by `rule`.
    defp pure_elixir_run!(rule, overrides \\ %{}) do
      result =
        @fixture
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("deps_lock", %{})
        |> Map.put("package_checksum", "outer")
        |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

      result
      |> put_in(["systems", "pure_elixir"], result["systems"]["nerves_system_rpi4"])
      |> Map.put("host_portability", %{
        "status" => "pass",
        "reason" => nil,
        "portability_rule" => rule,
        "compile_observations" => %{}
      })
      |> Map.merge(overrides)
      |> ingest_with_artifact()
    end

    # The full run's toolchain build: 1.20/29, the default config, `:with`.
    defp full_run_build!(rule1_reason, opts \\ []) do
      row!(
        "jason",
        "1.4.1",
        Keyword.get(opts, :status, :pass),
        opts ++ [toolchain: "1.20/29", rule: 2, rule1_reason: rule1_reason, marked: true]
      )
    end

    defp results(system_pkg) do
      SystemResult
      |> Ash.Query.filter(system_pkg == ^system_pkg)
      |> Ash.read!(domain: Catalog)
    end

    test "are revoked when the full run's toolchain build says rule 1 refused it" do
      pure_elixir_run!(2)
      full_run_build!(@cmd, status: :skipped, reason: "closure dependency observed the host: x")
      [result] = results("pure_elixir")
      result_id = result.id
      assert "jason" in Catalog.packages_with_precompiled_files()

      assert {:dry_run,
              [
                %{
                  kind: :system_result,
                  package: "jason",
                  version: "1.4.1",
                  toolchain: nil,
                  rule1_reason: @cmd,
                  id: ^result_id
                }
              ]} = ToolchainRevocation.revoke(all: true)

      assert Map.has_key?(Catalog.precompiled_manifest("jason").versions["1.4.1"], "pure_elixir")
      before = Catalog.precompiled_fingerprints()["jason"]

      assert {:revoked, 1, [%{kind: :system_result, id: ^result_id}], at} =
               ToolchainRevocation.revoke(dry_run: false, rule1_prefix: "calls System.cmd/")

      assert %{unpublished_at: %DateTime{}} = reload(result)
      assert Enum.all?(results("nerves_system_rpi4"), &is_nil(&1.unpublished_at))
      assert Catalog.precompiled_fingerprints()["jason"] != before
      refute Map.has_key?(Catalog.precompiled_manifest("jason").versions["1.4.1"], "pure_elixir")
      assert [{^at, 1}] = ToolchainRevocation.revocations()
      assert {:revoked, 0, [], _} = ToolchainRevocation.revoke(dry_run: false, all: true)

      assert {:ok, 1} = ToolchainRevocation.undo(at)
      assert %{unpublished_at: nil} = reload(result)
    end

    test "one call revokes the build and the result it vouches for" do
      pure_elixir_run!(2)
      build = full_run_build!(@cmd)

      assert {:revoked, 2, rows, at} =
               ToolchainRevocation.revoke(dry_run: false, package: "jason", version: "1.4.1")

      assert Enum.sort(Enum.map(rows, & &1.kind)) == [:system_result, :toolchain_build]
      assert reload(build).revoked_at == at
      assert [{^at, 2}] = ToolchainRevocation.revocations()
      assert {:ok, 2} = ToolchainRevocation.undo(at)
    end

    test "are left alone when rule 1 passed or no build says what it said" do
      # Rule 1 passed the full run's build: no reason.
      pure_elixir_run!(2)
      full_run_build!(nil)
      assert {:dry_run, []} = ToolchainRevocation.revoke(all: true)

      # No toolchain build of the full run's identity says what rule 1 said.
      for opts <- [
            [toolchain: "1.19/28"],
            [variant: :without],
            [config_variant: "phx_dev"],
            [builder_version: 0]
          ] do
        Repo.query!("DELETE FROM catalog_toolchain_builds")
        # Skipped, so the build itself is not a candidate either.
        full_run_build!(
          @cmd,
          opts ++ [status: :skipped, reason: "closure dependency observed the host: x"]
        )

        assert {:dry_run, []} = ToolchainRevocation.revoke(all: true), inspect(opts)
      end
    end

    test "a result rule 1 published is left alone" do
      pure_elixir_run!(nil)
      full_run_build!(@cmd)
      assert {:dry_run, [%{kind: :toolchain_build}]} = ToolchainRevocation.revoke(all: true)
    end
  end
end
