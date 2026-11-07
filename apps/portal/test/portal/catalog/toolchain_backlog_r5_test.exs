defmodule Portal.Catalog.ToolchainBacklogR5Test do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @lv %{"phoenix_live_view" => %{"version" => "1.2.13", "checksum" => "c"}}
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
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: Keyword.get(opts, :deps_lock, %{}),
      compile_env_rule: Keyword.get(opts, :compile_env_rule, if(marked?, do: 1)),
      compile_env: Keyword.get(opts, :compile_env, if(marked?, do: @env)),
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

  defp mark!(row),
    do:
      row
      |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
      |> Ash.update!(domain: Catalog)

  test "the reason the query matches is the one marked rows carry" do
    assert ToolchainBuild.withheld_revocation() == "withheld closure"
  end

  test "an unmarked pass row is rebuilt once a week old; a marked one never" do
    run!("unmarked", "1.0.0")
    row!("unmarked", "1.0.0", :pass, [])
    run!("marked", "1.0.0")
    row!("marked", "1.0.0", :pass, marked: true)

    assert names() == ["unmarked"]
  end

  test "rule 1 without a compile_env list is not the mark" do
    run!("rule_only", "1.0.0")
    row!("rule_only", "1.0.0", :pass, compile_env_rule: 1)
    run!("other_rule", "1.0.0")
    row!("other_rule", "1.0.0", :pass, compile_env_rule: 2, compile_env: @env)

    assert Enum.sort(names()) == ["other_rule", "rule_only"]
  end

  test "a mark another run wrote, or one with no run, is not the mark" do
    run!("stale", "1.0.0")
    stale = row!("stale", "1.0.0", :pass, marked: true)
    run!("no_run", "1.0.0")
    row!("no_run", "1.0.0", :pass, marked: true, run_id: nil)
    run!("kept", "1.0.0")
    row!("kept", "1.0.0", :pass, marked: true)

    assert stale.compile_env_run_id == stale.run_id

    # An older release's rebuild replaces run_id and compile_env and keeps
    # the mark it does not know about.
    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run', " <>
        "compile_env = '{}'::jsonb[] WHERE id = $1",
      [Ecto.UUID.dump!(stale.id)]
    )

    assert Enum.sort(names()) == ["no_run", "stale"]
  end

  test "a fresh unmarked pass row is not reopened (a rolled-back image)" do
    run!("fresh", "1.0.0")
    row!("fresh", "1.0.0", :pass, finished_at: ago(2 * @day))
    assert backlog() == []
  end

  test "an unmarked pass row is not reopened within a week of its last attempt" do
    run!("tried", "1.0.0")
    row!("tried", "1.0.0", :pass, attempted_at: ago(3 * @day))
    assert backlog() == []
  end

  test "new versions and withheld rows come before plain rebuilds, whatever the downloads" do
    run!("plain", "1.0.0")
    row!("plain", "1.0.0", :pass, [])
    downloads!("plain", 1_000_000)
    run!("withheld", "1.0.0")
    row!("withheld", "1.0.0", :pass, deps_lock: @lv)
    downloads!("withheld", 10)
    run!("new", "1.0.0")
    downloads!("new", 1)

    assert [
             %{package: "withheld", refresh: false},
             %{package: "new", refresh: false},
             %{package: "plain", refresh: true}
           ] = backlog()
  end

  test "the download ranking puts versions to refresh after the rest" do
    run!("served", "1.0.0")
    row!("served", "1.0.0", :pass, [])
    downloads!("served", 1_000_000)
    run!("new", "1.0.0")
    downloads!("new", 5)

    assert Catalog.toolchain_backlog_to_rank(1, 2) == [%{package: "new", version: "1.0.0"}]

    assert Catalog.toolchain_backlog_to_rank(2, 2) == [
             %{package: "new", version: "1.0.0"},
             %{package: "served", version: "1.0.0"}
           ]
  end

  test "within a package, a version to refresh ranks after a new one" do
    run!("pkg", "1.0.0")
    run!("pkg", "2.0.0")
    row!("pkg", "2.0.0", :pass, [])
    downloads!("pkg", 5)

    assert Catalog.toolchain_backlog_to_rank(1, 1) == [%{package: "pkg", version: "1.0.0"}]
  end

  test "a pass row with no recorded lock is withheld and ranks as a new version" do
    run!("plain", "1.0.0")
    row!("plain", "1.0.0", :pass, [])
    downloads!("plain", 1_000_000)
    run!("nolock", "1.0.0")
    row!("nolock", "1.0.0", :pass, deps_lock: nil)
    downloads!("nolock", 1)

    assert names() == ["nolock", "plain"]
  end

  test "a row revoked for its withheld closure is rebuilt; any other revoked row is not" do
    run!("lv_revoked", "1.0.0")
    "lv_revoked" |> row!("1.0.0", :pass, deps_lock: @lv) |> revoke!() |> mark!()
    run!("plain_revoked", "1.0.0")
    "plain_revoked" |> row!("1.0.0", :pass, deps_lock: @lv) |> revoke!()
    run!("marked_revoked", "1.0.0")

    "marked_revoked"
    |> row!("1.0.0", :pass, deps_lock: @lv, marked: true)
    |> revoke!()
    |> mark!()

    assert names() == ["lv_revoked"]
  end

  test "a row revoked for its withheld closure waits a week after its last attempt" do
    run!("lv_tried", "1.0.0")

    "lv_tried"
    |> row!("1.0.0", :pass, deps_lock: @lv, attempted_at: ago(3 * @day))
    |> revoke!()
    |> mark!()

    assert backlog() == []
  end

  test "a kept row with transient attempts is retried after a day, never at the cap" do
    run!("day_old", "1.0.0")
    row!("day_old", "1.0.0", :pass, transient_attempts: 1, attempted_at: ago(2 * @day))
    run!("hour_old", "1.0.0")
    row!("hour_old", "1.0.0", :pass, transient_attempts: 1, attempted_at: ago(3600))
    run!("capped", "1.0.0")
    row!("capped", "1.0.0", :pass, transient_attempts: 5, attempted_at: ago(30 * @day))
    run!("priv", "1.0.0")

    row!("priv", "1.0.0", :skipped,
      reason: "ships priv files",
      marked: true,
      transient_attempts: 2,
      attempted_at: ago(2 * @day)
    )

    assert Enum.sort(names()) == ["day_old", "priv"]
  end

  test "any kept pass or skipped row with transient attempts is retried after a day" do
    run!("marked_pass", "1.0.0")

    row!("marked_pass", "1.0.0", :pass,
      marked: true,
      transient_attempts: 1,
      attempted_at: ago(2 * @day)
    )

    run!("other_skip", "1.0.0")

    row!("other_skip", "1.0.0", :skipped,
      reason: "portability could not be judged",
      transient_attempts: 3,
      attempted_at: ago(2 * @day)
    )

    run!("marked_capped", "1.0.0")

    row!("marked_capped", "1.0.0", :pass,
      marked: true,
      transient_attempts: 5,
      attempted_at: ago(2 * @day)
    )

    assert Enum.sort(names()) == ["marked_pass", "other_skip"]
  end

  test "a skip at the transient cap stays out" do
    run!("gave_up", "1.0.0")

    row!("gave_up", "1.0.0", :skipped,
      reason: "portability could not be judged (transient 5 times)",
      transient_attempts: 5
    )

    assert backlog() == []
  end

  test "the admin count and the download ranking see the reopened rows" do
    run!("unmarked", "1.0.0")
    row!("unmarked", "1.0.0", :pass, [])
    downloads!("unmarked", 5)

    assert %{"1.19/28" => %{backlog: 1}} = Catalog.toolchain_counts()

    assert Catalog.toolchain_backlog_to_rank(10, 2) == [
             %{package: "unmarked", version: "1.0.0"}
           ]
  end
end
