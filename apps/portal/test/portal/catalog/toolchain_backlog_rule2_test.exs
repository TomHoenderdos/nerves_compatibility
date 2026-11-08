defmodule Portal.Catalog.ToolchainBacklogRule2Test do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @env [%{"app" => "demo", "key" => "mode", "value" => "x"}]

  # Rule-1 refusals rule 2 no longer has: a runtime program call, executable
  # lookup or shell, and the `:os.type`/`system_architecture` grep.
  @reopened [
    "calls System.cmd/2",
    "calls System.cmd/3",
    "calls System.shell/1",
    "calls System.shell/2",
    "calls os:cmd/1",
    "calls os:cmd/2",
    "calls erlang:open_port/2",
    "calls Port.open/2",
    "calls System.find_executable/1",
    "calls os:find_executable/1",
    "calls a shell",
    "runs an OS command",
    "calls an executable lookup",
    "OS-specific (lib/x.ex: :os.type()",
    "OS-specific (src/x.erl: os:type()",
    "OS-specific (lib/pages/home.ex: system_architecture)"
  ]

  @kept [
    "calls erlang:load_nif/2",
    "calls erl_ddll:load_driver/2",
    "calls a NIF or port driver",
    "calls natively built dependency at compile time: Mix.Tasks.Compile.ElixirMake.run/1",
    "OS-specific (rebar.config: platform_define)",
    "OS-specific (rebar.config.script: present)",
    "OS-specific (.: grep failed)",
    "reads the target or ships native code",
    "ships an executable priv file: priv/run",
    "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)",
    "closure dependency observed the host: fine",
    "portability could not be judged",
    "no compiled beams"
  ]

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

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # `marked: true` gives the row the R5 mark: rule 1 next to a `compile_env`.
  defp row!(name, version, status, opts) do
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
    marked? = Keyword.get(opts, :marked, false)

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: version,
      toolchain: "1.19/28",
      builder_version: 1,
      variant: Keyword.get(opts, :variant, :with),
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: Keyword.get(opts, :deps_lock, %{}),
      compile_env_rule: Keyword.get(opts, :compile_env_rule, if(marked?, do: 1)),
      compile_env: Keyword.get(opts, :compile_env, if(marked?, do: @env)),
      portability_rule: Keyword.get(opts, :rule),
      optional_deps: Keyword.get(opts, :optional_deps),
      run_id: Keyword.get(opts, :run_id, "tc-#{name}-#{version}"),
      transient_attempts: Keyword.get(opts, :transient_attempts, 0),
      attempted_at: Keyword.get(opts, :attempted_at),
      finished_at: Keyword.get(opts, :finished_at, ago(30 * @day))
    })
    |> Ash.create!(domain: Catalog)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp backlog, do: Catalog.toolchain_backlog("1.19/28", 1, 100)
  defp names, do: Enum.map(backlog(), & &1.package)

  defp revoke!(row),
    do: row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)

  # A rule-2 build on the toolchain, finished `age` seconds ago.
  defp rule2!(age \\ 3600) do
    run!("rule2_marker", "1.0.0")
    row!("rule2_marker", "1.0.0", :pass, rule: 2, marked: true, finished_at: ago(age))
  end

  test "every rule-1 runtime-call and OS-grep reason reopens once rule 2 has built" do
    for {reason, i} <- Enum.with_index(@reopened) do
      run!("p#{i}", "1.0.0")
      row!("p#{i}", "1.0.0", :skipped, reason: reason, finished_at: ago(2 * @day))
    end

    rule2!()

    assert Enum.sort(names()) ==
             Enum.sort(for {_r, i} <- Enum.with_index(@reopened), do: "p#{i}")
  end

  test "no other reason reopens, rule 1 or not" do
    for {reason, i} <- Enum.with_index(@kept) do
      run!("k#{i}", "1.0.0")
      row!("k#{i}", "1.0.0", :skipped, reason: reason, finished_at: ago(30 * @day))
    end

    rule2!()
    assert names() == []
  end

  test "a nerves-specific source row stays closed: rule 2 keeps the Nerves check" do
    run!("nervesy", "1.0.0")

    row!("nervesy", "1.0.0", :skipped,
      reason: "nerves-specific source",
      finished_at: ago(30 * @day)
    )

    rule2!()
    assert names() == []
  end

  test "a skipped row with no reason stays closed" do
    run!("noreason", "1.0.0")
    row!("noreason", "1.0.0", :skipped, finished_at: ago(30 * @day))

    rule2!()
    assert names() == []
  end

  test "nothing reopens before any rule-2 row exists on the toolchain" do
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "calls System.cmd/2", finished_at: ago(30 * @day))

    assert names() == []
  end

  test "a rule-2 row of another toolchain or builder version does not count" do
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "calls System.cmd/2", finished_at: ago(30 * @day))
    run!("other", "1.0.0")
    other = row!("other", "1.0.0", :pass, rule: 2, marked: true, finished_at: ago(3600))

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET toolchain = '1.20/29' WHERE id = $1",
      [Ecto.UUID.dump!(other.id)]
    )

    # `other` itself now has no row on this toolchain and builder version.
    assert names() == ["other"]

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET toolchain = '1.19/28', builder_version = 2 " <>
        "WHERE id = $1",
      [Ecto.UUID.dump!(other.id)]
    )

    # `other` itself now has no row on this toolchain and builder version.
    assert names() == ["other"]
  end

  test "a rule-1 row newer than the newest rule-2 row is not reopened (rolled-back image)" do
    rule2!(3 * @day)
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "calls System.cmd/2", finished_at: ago(2 * @day))

    assert names() == []
  end

  test "a row attempted less than a day ago waits" do
    rule2!(60)
    run!("phoenix", "1.8.16")

    row!("phoenix", "1.8.16", :skipped,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day),
      attempted_at: ago(3600)
    )

    assert names() == []
  end

  test "after a non-transient attempt the row waits a week; after a transient one a day" do
    rule2!(60)
    run!("week", "1.0.0")

    row!("week", "1.0.0", :skipped,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day),
      attempted_at: ago(2 * @day)
    )

    run!("weekold", "1.0.0")

    row!("weekold", "1.0.0", :skipped,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day),
      attempted_at: ago(8 * @day)
    )

    run!("transient", "1.0.0")

    row!("transient", "1.0.0", :skipped,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day),
      attempted_at: ago(2 * @day),
      transient_attempts: 1
    )

    assert Enum.sort(names()) == ["transient", "weekold"]
  end

  test "a rule-2 row never reopens for a rule-1 reason; transient cap and revocation hold" do
    rule2!()
    run!("ruled", "1.0.0")

    row!("ruled", "1.0.0", :skipped,
      rule: 2,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day)
    )

    run!("capped", "1.0.0")

    row!("capped", "1.0.0", :skipped,
      reason: "calls System.cmd/2",
      finished_at: ago(30 * @day),
      transient_attempts: ToolchainBuild.transient_cap()
    )

    run!("revoked", "1.0.0")

    "revoked"
    |> row!("1.0.0", :skipped, reason: "calls System.cmd/2", finished_at: ago(30 * @day))
    |> revoke!()

    assert names() == []
  end

  test "a reopened row ranks by downloads among new defaults, not as a refresh" do
    rule2!()
    run!("phoenix", "1.8.16")
    downloads!("phoenix", 6_000_000)
    row!("phoenix", "1.8.16", :skipped, reason: "calls System.cmd/2", finished_at: ago(30 * @day))
    run!("fresh", "1.0.0")
    downloads!("fresh", 10)

    assert [
             %{package: "phoenix", refresh: false, config_variant: "default"},
             %{package: "fresh"}
           ] = Enum.filter(backlog(), &(&1.package in ["phoenix", "fresh"]))
  end

  @added %{"added" => ["lazy_html"], "dropped" => [], "reason" => nil}

  defp variants(name), do: for(r <- backlog(), r.package == name, do: r.variant)

  test "any rule-2 skipped with that added an optional dependency wants without" do
    for {reason, i} <-
          Enum.with_index([
            "closure dependency observed the host: fine (bakes the build path: Elixir.Fine \"<root>\")",
            "calls natively built dependency at compile time: LazyHTML.from_fragment/1",
            "portability could not be judged",
            "dependency cc_precompiler reads the target",
            "nerves-specific source in dependency leaf",
            "compile-time host read: os:type/0 in X.f/0"
          ]) do
      run!("lv#{i}", "1.2.13")
      row!("lv#{i}", "1.2.13", :skipped, rule: 2, reason: reason, optional_deps: @added)
      assert variants("lv#{i}") == [:without], reason
    end
  end

  test "no without for a rule-1 skip or a with that added nothing" do
    cases = [
      {[reason: "closure dependency observed the host: fine", optional_deps: @added]},
      {[reason: "portability could not be judged", optional_deps: @added]},
      {[
         rule: 2,
         reason: "portability could not be judged",
         optional_deps: %{"added" => [], "dropped" => [], "reason" => nil}
       ]}
    ]

    for {{opts}, i} <- Enum.with_index(cases) do
      run!("n#{i}", "1.0.0")
      row!("n#{i}", "1.0.0", :skipped, opts)
      assert variants("n#{i}") == [], "case #{i}"
    end
  end

  test "a revoked rule-2 skipped with wants no without" do
    run!("lv", "1.2.13")

    "lv"
    |> row!("1.2.13", :skipped,
      rule: 2,
      reason: "portability could not be judged",
      optional_deps: @added
    )
    |> revoke!()

    assert variants("lv") == []
  end

  test "a live without row ends it" do
    run!("lv", "1.2.13")

    row!("lv", "1.2.13", :skipped,
      rule: 2,
      reason: "closure dependency observed the host: fine",
      optional_deps: @added
    )

    row!("lv", "1.2.13", :pass,
      rule: 2,
      marked: true,
      variant: :without,
      run_id: "tc-lv-without"
    )

    assert variants("lv") == []
  end
end
