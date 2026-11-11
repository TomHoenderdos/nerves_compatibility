defmodule Portal.Catalog.ToolchainBacklogJudgeRevisionTest do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @env [%{"app" => "demo", "key" => "mode", "value" => "x"}]

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

  defp row!(name, version, status, opts) do
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
    marked? = Keyword.get(opts, :marked, false)

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: version,
      toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
      builder_version: Keyword.get(opts, :builder_version, 1),
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: %{},
      compile_env_rule: if(marked?, do: 1),
      compile_env: if(marked?, do: @env),
      portability_rule: Keyword.get(opts, :rule),
      judge_revision: Keyword.get(opts, :judge_revision),
      run_id: "tc-#{name}-#{version}-#{System.unique_integer([:positive])}",
      transient_attempts: Keyword.get(opts, :transient_attempts, 0),
      attempted_at: Keyword.get(opts, :attempted_at),
      finished_at: Keyword.get(opts, :finished_at, ago(30 * @day))
    })
    |> Ash.create!(domain: Catalog)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp names, do: Enum.map(Catalog.toolchain_backlog("1.19/28", 1, 100), & &1.package)

  defp revoke!(row),
    do: row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)

  # A passing build on the toolchain at `revision`, finished `age` ago.
  defp revised!(revision, age \\ 3600, opts \\ []) do
    run!("marker#{revision}", "1.0.0")

    row!(
      "marker#{revision}",
      "1.0.0",
      :pass,
      [rule: 2, marked: true, judge_revision: revision, finished_at: ago(age)] ++ opts
    )
  end

  @reasons [
    nil,
    "nerves-specific source",
    "reads the target or ships native code",
    "OS-specific (rebar.config: platform_define)",
    "rebar3 build uses platform_define",
    "compile-time host read: erlang:system_info/1 in parse_trans.get_file/1 (src/parse_trans.erl:226)",
    "closure dependency observed the host: ranch (reads the target or ships native code)",
    "portability could not be judged"
  ]

  test "every skipped row below the newest revision reopens once, any reason, any rule" do
    for {reason, i} <- Enum.with_index(@reasons), rule <- [nil, 2] do
      name = "p#{i}_#{rule}"
      run!(name, "1.0.0")
      row!(name, "1.0.0", :skipped, reason: reason, rule: rule)
    end

    revised!(1)

    assert Enum.sort(names()) ==
             Enum.sort(
               for {_r, i} <- Enum.with_index(@reasons), rule <- [nil, 2], do: "p#{i}_#{rule}"
             )
  end

  test "nothing reopens before any row on the toolchain carries a revision" do
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "nerves-specific source")
    run!("plain", "1.0.0")
    row!("plain", "1.0.0", :pass, rule: 2, marked: true, finished_at: ago(3600))

    assert names() == []
  end

  test "a row at the newest revision stays closed; one below it reopens" do
    revised!(2)
    run!("current", "1.0.0")
    row!("current", "1.0.0", :skipped, reason: "nerves-specific source", judge_revision: 2)
    run!("older", "1.0.0")
    row!("older", "1.0.0", :skipped, reason: "nerves-specific source", judge_revision: 1)

    assert names() == ["older"]
  end

  # A rollback: the image went back to an older revision after the last
  # newest-revision build, and rebuilt the row since. Not reopened again.
  test "a row newer than the newest build at the newest revision stays closed" do
    revised!(1, 9 * @day)
    # The rolled-back image's own build, after the row's last activity: only
    # builds at the newest revision count, so it does not reopen the row.
    run!("oldimage", "1.0.0")
    row!("oldimage", "1.0.0", :pass, rule: 2, marked: true, finished_at: ago(3600))
    run!("phoenix", "1.8.16")

    row!("phoenix", "1.8.16", :skipped,
      reason: "nerves-specific source",
      attempted_at: ago(8 * @day)
    )

    assert names() == []
  end

  test "a row that is not due yet waits" do
    revised!(1)
    run!("fresh", "1.0.0")
    row!("fresh", "1.0.0", :skipped, reason: "nerves-specific source", finished_at: ago(2 * @day))

    assert names() == []
  end

  test "transient-capped and revoked rows stay closed" do
    revised!(1)
    run!("capped", "1.0.0")

    row!("capped", "1.0.0", :skipped,
      reason: "portability could not be judged",
      transient_attempts: ToolchainBuild.transient_cap()
    )

    run!("revoked", "1.0.0")

    "revoked"
    |> row!("1.0.0", :skipped, reason: "nerves-specific source")
    |> revoke!()

    assert names() == []
  end

  test "a revision on another toolchain or builder version does not count" do
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "nerves-specific source")
    other = revised!(1)

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET toolchain = '1.20/29' WHERE id = $1",
      [Ecto.UUID.dump!(other.id)]
    )

    # `marker1` itself now has no row on this toolchain: a new default.
    assert names() == ["marker1"]
  end

  test "a revision at another builder version does not count" do
    run!("phoenix", "1.8.16")
    row!("phoenix", "1.8.16", :skipped, reason: "nerves-specific source")
    revised!(1, 3600, builder_version: 2)

    # `marker1` has no row at builder version 1: a new default.
    assert names() == ["marker1"]
  end

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  test "a reopened row ranks behind a new version, whatever its downloads" do
    revised!(1)
    downloads!("marker1", 0)
    run!("hot", "1.0.0")
    downloads!("hot", 1_000_000)
    row!("hot", "1.0.0", :skipped, reason: "nerves-specific source")
    run!("cold", "1.0.0")
    downloads!("cold", 1)

    assert [%{package: "cold", reopen: false}] = Catalog.toolchain_backlog("1.19/28", 1, 1)

    assert Enum.map(Catalog.toolchain_backlog("1.19/28", 1, 100), &{&1.package, &1.reopen}) ==
             [{"cold", false}, {"hot", true}]
  end

  # A registry-only version (the bulk intake's `registry_deps` pass, nothing
  # compiled) is new work, so it ranks ahead of every reopen too.
  test "a registry-only version ranks ahead of a reopened row, whatever its downloads" do
    revised!(1)
    downloads!("marker1", 0)
    run!("hot", "1.0.0")
    downloads!("hot", 1_000_000)
    row!("hot", "1.0.0", :skipped, reason: "nerves-specific source")
    {:ok, _run} = Portal.Catalog.RegistryAssessment.record("csv", "3.2.2", nil)
    downloads!("csv", 1)

    assert [%{package: "csv", reopen: false}] = Catalog.toolchain_backlog("1.19/28", 1, 1)

    assert Enum.map(Catalog.toolchain_backlog("1.19/28", 1, 100), &{&1.package, &1.reopen}) ==
             [{"csv", false}, {"hot", true}]
  end

  # An older release the version backfill nominates (`Portal.Catalog.VersionBackfill`)
  # is new work as well: it ranks ahead of every reopen.
  test "a backfilled old release ranks ahead of a reopened row, whatever its downloads" do
    revised!(1)
    downloads!("marker1", 0)
    run!("hot", "1.0.0")
    downloads!("hot", 1_000_000)
    row!("hot", "1.0.0", :skipped, reason: "nerves-specific source")
    run!("cold", "2.0.0")
    downloads!("cold", 1)
    row!("cold", "2.0.0", :pass, rule: 2, marked: true, judge_revision: 1)

    Process.put({Portal.Test.FakeHexDeps, :releases}, %{
      "cold" =>
        Enum.map(
          ["1.0.0", "2.0.0"],
          &%{version: &1, retired?: false, deps: [], outer_checksum: nil}
        )
    })

    assert [%{package: "cold", version: "1.0.0", reopen: false}] =
             Catalog.toolchain_backlog("1.19/28", 1, 1)

    assert Enum.map(Catalog.toolchain_backlog("1.19/28", 1, 100), &{&1.package, &1.reopen}) ==
             [{"cold", false}, {"hot", true}]
  end

  test "a row another rule reopens too is not marked as a reopen" do
    revised!(1)
    run!("priv", "1.0.0")
    row!("priv", "1.0.0", :skipped, reason: "ships priv files")

    assert [%{package: "priv", reopen: false}] = Catalog.toolchain_backlog("1.19/28", 1, 100)
  end
end
