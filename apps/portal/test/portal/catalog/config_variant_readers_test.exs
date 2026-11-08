defmodule Portal.Catalog.ConfigVariantReadersTest do
  # Not async: swaps the `Portal.Toolchains` application env, and drops the
  # legacy identity index inside the sandbox transaction.
  use Portal.DataCase, async: false

  require Ash.Query

  import Portal.PrecompiledFixtures

  alias Portal.Catalog
  alias Portal.Catalog.{Coverage, Ingestion, Package, ToolchainBuild, UnrecordedOptionalDeps}
  alias Portal.Precompiled.PureElixirWithdrawal

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @env [%{"app" => "demo", "key" => "mode", "value" => "x"}]
  @host_read "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)"

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
    drop_legacy_identity_index!()
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

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # `marked: true` gives the row the R5 mark: rule 1 next to a `compile_env`,
  # written by the row's own run.
  defp row!(name, version, status, opts) do
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
    marked? = Keyword.get(opts, :marked, false)
    config_variant = Keyword.get(opts, :config_variant, "default")

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: version,
      toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
      builder_version: Keyword.get(opts, :builder_version, 1),
      variant: Keyword.get(opts, :variant, :with),
      config_variant: config_variant,
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: Keyword.get(opts, :deps_lock, %{}),
      optional_deps: Keyword.get(opts, :optional_deps),
      compile_observations: Keyword.get(opts, :compile_observations),
      compile_env_rule: if(marked?, do: 1),
      compile_env: if(marked?, do: @env),
      run_id: "tc-#{name}-#{version}-#{config_variant}",
      finished_at: Keyword.get(opts, :finished_at, ago(30 * @day))
    })
    |> Ash.create!(domain: Catalog)
  end

  # A row of a named config variant, marked unless told otherwise.
  defp named_row!(name, version, config_variant, status, opts \\ []) do
    row!(
      name,
      version,
      status,
      Keyword.merge([marked: true], opts) |> Keyword.put(:config_variant, config_variant)
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp backlog, do: Catalog.toolchain_backlog("1.19/28", 1, 50)
  defp backlog(name), do: Enum.filter(backlog(), &(&1.package == name))

  # The packages `UnrecordedOptionalDeps.wanted/3` asks the registry about.
  # The registry answers nothing, so nothing is recorded and the call can be
  # repeated.
  defp unrecorded_asked do
    test_pid = self()

    hex_releases = fn name ->
      send(test_pid, {:asked, name})
      {:error, :unavailable}
    end

    assert UnrecordedOptionalDeps.wanted("1.19/28", 1, hex_releases: hex_releases) == {[], []}
    collect_asked([])
  end

  defp collect_asked(names) do
    receive do
      {:asked, name} -> collect_asked([name | names])
    after
      0 -> Enum.sort(names)
    end
  end

  defp coverage, do: Coverage.report(optional_deps_complete?: fn _build -> true end)

  describe "a named variant row changes no default-side answer" do
    test "the backlog still wants the default when only a named row exists" do
      run!("rdpkg", "1.0.0")
      before = backlog()
      assert [%{package: "rdpkg", variant: :with, refresh: false}] = before

      named_row!("rdpkg", "1.0.0", "phx_prod", :pass)

      assert backlog() == before
      assert Enum.all?(before, &(&1.config_variant == "default"))
    end

    test "a named with-row that added an optional dep does not want a without build" do
      run!("rdpkg2", "1.0.0")
      row!("rdpkg2", "1.0.0", :pass, marked: true, optional_deps: %{"added" => []})

      named_row!("rdpkg2", "1.0.0", "phx_prod", :pass, optional_deps: %{"added" => ["decimal"]})

      assert backlog("rdpkg2") == []
    end

    test "a named pass does not stand in for an unmarked default's refresh" do
      run!("rdpkg3", "1.0.0")
      row!("rdpkg3", "1.0.0", :pass, marked: false, finished_at: ago(8 * @day))
      named_row!("rdpkg3", "1.0.0", "phx_prod", :pass)

      assert [%{package: "rdpkg3", refresh: true, config_variant: "default"}] = backlog("rdpkg3")
    end

    test "an unmarked named pass does not make a default's build a refresh" do
      run!("rdpkg4", "1.0.0")
      row!("rdpkg4", "1.0.0", :fail, marked: true, finished_at: ago(8 * @day))
      named_row!("rdpkg4", "1.0.0", "phx_prod", :pass, marked: false)

      assert [%{package: "rdpkg4", refresh: false, config_variant: "default"}] = backlog("rdpkg4")
    end

    test "UnrecordedOptionalDeps: a named without row does not settle a default's" do
      run!("rduod1", "1.0.0")
      row!("rduod1", "1.0.0", :pass, marked: true, optional_deps: nil)
      assert unrecorded_asked() == ["rduod1"]

      named_row!("rduod1", "1.0.0", "phx_prod", :pass, variant: :without)

      assert unrecorded_asked() == ["rduod1"]
    end

    test "UnrecordedOptionalDeps: an unrecorded named with row is not asked about" do
      run!("rduod2", "1.0.0")
      row!("rduod2", "1.0.0", :pass, marked: true, optional_deps: %{"added" => []})
      assert unrecorded_asked() == []

      named_row!("rduod2", "1.0.0", "phx_prod", :pass, optional_deps: nil)

      assert unrecorded_asked() == []
    end

    test "Coverage: a named pass does not cover a version whose default failed" do
      run!("rdcov", "1.0.0")
      downloads!("rdcov", 1_000)
      row!("rdcov", "1.0.0", :fail, marked: true)
      before = coverage()

      named_row!("rdcov", "1.0.0", "phx_prod", :pass)

      assert coverage() == before
    end

    test "PureElixirWithdrawal: a named skip withdraws no published result" do
      ingest_with_artifact(
        result_fixture_pure_elixir(%{"deps_lock" => %{}, "package_checksum" => "outer"})
      )

      before = PureElixirWithdrawal.candidates()
      assert before == []

      named_row!("jason", "1.4.1", "phx_dev", :skipped,
        toolchain: "1.20/29",
        reason: @host_read,
        compile_observations: %{"refusals" => []}
      )

      assert PureElixirWithdrawal.candidates() == before
    end

    test "toolchain_counts/0 counts default rows only" do
      run!("rdcount", "1.0.0")
      row!("rdcount", "1.0.0", :pass, marked: true)
      before = Catalog.toolchain_counts()
      assert %{"1.19/28" => %{pass: 1}} = before

      named_row!("rdcount", "1.0.0", "phx_prod", :pass)
      named_row!("rdcount", "1.0.0", "phx_dev", :skipped, reason: "calls System.cmd/3")

      assert Catalog.toolchain_counts() == before
    end
  end

  test "every SQL reader of catalog_toolchain_builds in lib names config_variant" do
    for path <- Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__)),
        text = File.read!(path),
        String.contains?(text, "catalog_toolchain_builds") do
      assert String.contains?(text, "config_variant"), "#{path} reads catalog_toolchain_builds"
    end
  end

  # The fixture's jason run with its publishing rpi4 result also published
  # as the run's pure_elixir result, as `pure_elixir_withdrawal_test.exs`
  # builds it.
  defp result_fixture_pure_elixir(overrides) do
    result =
      [__DIR__, "..", "..", "support", "fixtures", "result.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(overrides)
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

    put_in(result, ["systems", "pure_elixir"], result["systems"]["nerves_system_rpi4"])
  end
end
