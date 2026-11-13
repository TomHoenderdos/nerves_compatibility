defmodule Portal.Catalog.UnknownVariantTest do
  # A toolchain build row whose optional-deps `variant` this release does not
  # know, as a newer release may write one: every reader leaves it out, and
  # none crashes on it. The rows are written with raw SQL, the way a newer
  # release's would arrive, since this release's `ToolchainBuild` refuses to
  # create one. The variant names are never atoms in this file: a name this
  # release never mentions has no atom, which is what an older node meets.
  #
  # Not async: swaps the `Portal.Toolchains` application env.
  use PortalWeb.ConnCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Phoenix.LiveViewTest
  import Portal.PrecompiledFixtures
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Coverage, Ingestion, NotPrecompiled, Package, ToolchainBuild}
  alias Portal.Repo
  alias Portal.Workers.ToolchainBuild, as: ToolchainBuildWorker
  alias Portal.Workers.ToolchainSweep

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @world "world_phx"
  @pw "correct horse battery staple"

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      previous
      |> Keyword.merge(
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
      |> Keyword.delete(:config_variants)
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    drop_legacy_identity_index!()
    :ok
  end

  defp name, do: "uv_#{System.unique_integer([:positive])}"

  # A host pass of `name` `version`, which makes the version a backlog
  # candidate.
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

  # A served, marked `with` default build of `name` whose closure read the
  # LiveView keys, so the backlog wants its named config variants.
  defp served!(name, version) do
    run!(name, version)

    ingest_toolchain_build(name, version,
      compile_env: lv_default_env(),
      compile_env_rule: 1
    )
  end

  # Copies the toolchain build `id`, its file memberships included, as a row
  # of `variant`, a day newer and with a lock of its own, so a reader that
  # took it would show it as a build of its own. Raw SQL: every column of the
  # table, whatever columns a newer release adds.
  defp copy_as!(id, variant, set \\ "") do
    columns = columns("catalog_toolchain_builds")

    select =
      Enum.map_join(columns, ", ", fn
        "id" -> "$2::uuid"
        "variant" -> "$3::text"
        "finished_at" -> "finished_at + interval '1 day'"
        "deps_lock" -> ~s|deps_lock \|\| '{"world_extra": {"version": "1.0.0"}}'::jsonb|
        column -> column
      end)

    new_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO catalog_toolchain_builds (#{Enum.join(columns, ", ")}) " <>
        "SELECT #{select} FROM catalog_toolchain_builds WHERE id = $1::uuid",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(new_id), variant]
    )

    if set != "" do
      Repo.query!("UPDATE catalog_toolchain_builds SET #{set} WHERE id = $1::uuid", [
        Ecto.UUID.dump!(new_id)
      ])
    end

    memberships = columns("catalog_artifact_memberships")

    member_select =
      Enum.map_join(memberships, ", ", fn
        "id" -> "gen_random_uuid()"
        "toolchain_build_id" -> "$2::uuid"
        column -> column
      end)

    Repo.query!(
      "INSERT INTO catalog_artifact_memberships (#{Enum.join(memberships, ", ")}) " <>
        "SELECT #{member_select} FROM catalog_artifact_memberships " <>
        "WHERE toolchain_build_id = $1::uuid",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(new_id)]
    )

    new_id
  end

  defp delete!(id) do
    for table <- ["catalog_artifact_memberships", "catalog_toolchain_builds"] do
      column = if table == "catalog_toolchain_builds", do: "id", else: "toolchain_build_id"
      Repo.query!("DELETE FROM #{table} WHERE #{column} = $1::uuid", [Ecto.UUID.dump!(id)])
    end
  end

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = $1 ORDER BY ordinal_position",
        [table]
      )

    List.flatten(rows)
  end

  defp variants_in_table(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT t.variant FROM catalog_toolchain_builds t " <>
          "JOIN catalog_packages p ON p.id = t.package_id WHERE p.name = $1 ORDER BY 1",
        [name]
      )

    List.flatten(rows)
  end

  test "the variant name stays unknown to the VM, as on an older node" do
    assert_raise ArgumentError, fn -> String.to_existing_atom(@world) end
  end

  describe "manifests" do
    test "both formats leave the unknown row out and render the rest" do
      name = name()
      tb = served!(name, "1.0.0")
      v1 = Catalog.precompiled_manifest(name)
      v2 = Catalog.precompiled_manifest_v2(name)
      both = Catalog.precompiled_manifests(name)
      assert [_build] = v2["versions"]["1.0.0"]["builds"]

      copy_as!(tb.id, @world)
      assert variants_in_table(name) == ["with", @world]

      assert Catalog.precompiled_manifest(name) == v1
      assert Catalog.precompiled_manifest_v2(name) == v2
      assert Catalog.precompiled_manifests(name) == both
    end

    test "a package whose only build is of an unknown variant publishes nothing" do
      name = name()
      tb = served!(name, "1.0.0")
      copy_as!(tb.id, @world)
      delete!(tb.id)

      assert Catalog.precompiled_manifest_v2(name) == nil
      refute name in Catalog.packages_with_precompiled_files()
    end

    test "a blob only an unknown-variant row owns is not served" do
      name = name()
      tb = served!(name, "1.0.0")
      [%{"sha256" => sha}] = tb.file_manifest["ebin"]
      assert Catalog.published_sha256?(sha)

      copy_as!(tb.id, @world)
      delete!(tb.id)

      refute Catalog.published_sha256?(sha)
    end

    test "a variant whose name is an existing atom is left out too" do
      name = name()
      tb = served!(name, "1.0.0")
      v2 = Catalog.precompiled_manifest_v2(name)

      # `default` is an atom in every VM; Ash would load it without its
      # `one_of` check.
      copy_as!(tb.id, "default")

      assert Catalog.precompiled_manifest_v2(name) == v2
    end

    test "the fingerprint does not move for an unknown-variant row" do
      name = name()
      tb = served!(name, "1.0.0")
      before = Map.fetch!(Catalog.precompiled_fingerprints(), name)

      copy_as!(tb.id, @world)

      assert Map.fetch!(Catalog.precompiled_fingerprints(), name) == before
    end
  end

  describe "Ash reads" do
    test "a read of every row of the package loads only the known variants" do
      name = name()
      tb = served!(name, "1.0.0")
      copy_as!(tb.id, @world)

      assert [%ToolchainBuild{variant: :with}] =
               ToolchainBuild
               |> Ash.Query.filter(package.name == ^name)
               |> Ash.read!(domain: Catalog)
    end

    test "a create still refuses a variant this release does not know" do
      name = name()
      run!(name, "1.0.0")
      package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)

      assert {:error, %Ash.Error.Invalid{}} =
               ToolchainBuild
               |> Ash.Changeset.for_create(:create, %{
                 package_id: package.id,
                 version: "1.0.0",
                 toolchain: "1.19/28",
                 builder_version: 1,
                 variant: @world,
                 status: :pass
               })
               |> Ash.create(domain: Catalog)
    end

    test "mark_withheld_revoked treats an unknown-variant row as missing" do
      name = name()
      tb = served!(name, "1.0.0")
      id = copy_as!(tb.id, @world, "revoked_at = now()")

      assert %{marked: [], skipped: [{^id, "no such toolchain build"}]} =
               Catalog.mark_withheld_revoked([id])
    end
  end

  describe "backlog and sweep" do
    test "the backlog never names an unknown variant and the sweep runs" do
      name = name()
      tb = served!(name, "1.0.0")
      before = Catalog.toolchain_backlog("1.19/28", 1, 50, backfill: [])
      assert Enum.any?(before, &(&1.package == name and &1.config_variant != "default"))

      copy_as!(tb.id, @world)

      backlog = Catalog.toolchain_backlog("1.19/28", 1, 50, backfill: [])
      assert backlog == before
      assert Enum.all?(backlog, &(&1.variant in [:with, :without]))

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuildWorker)
      assert jobs != []
      assert Enum.all?(jobs, &(&1.args["variant"] in ["with", "without"]))
    end

    test "toolchain_counts does not count an unknown-variant row" do
      name = name()
      tb = served!(name, "1.0.0")
      before = Catalog.toolchain_counts()

      copy_as!(tb.id, @world)
      skipped = copy_as!(tb.id, "world_other", "status = 'skipped'")
      assert is_binary(skipped)

      assert Catalog.toolchain_counts() == before
    end
  end

  describe "coverage, not precompiled and admin pages" do
    setup %{conn: conn} do
      {:ok, admin} = Portal.Accounts.seed_admin_user("uv_admin", @pw)
      admin = add_test_passkey(admin)
      %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey)}
    end

    defp coverage, do: Coverage.report(optional_deps_complete?: fn _build -> true end)

    test "coverage leaves an unknown-variant row out" do
      name = name()
      run!(name, "1.0.0")

      Package
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(domain: Catalog)
      |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: 1_000})
      |> Ash.update!(domain: Catalog)

      tb = ingest_toolchain_build(name, "1.0.0", status: "skipped")
      before = coverage()

      copy_as!(tb.id, @world, "status = 'pass'")

      assert coverage() == before
    end

    test "NotPrecompiled leaves an unknown-variant skip out" do
      name = name()
      tb = served!(name, "1.0.0")
      before = NotPrecompiled.rows()

      copy_as!(tb.id, @world, "status = 'skipped', reason = 'calls a shell'")

      assert NotPrecompiled.rows() == before
    end

    test "the maintenance and not-precompiled pages render", %{conn: conn} do
      name = name()
      tb = served!(name, "1.0.0")
      copy_as!(tb.id, @world)
      copy_as!(tb.id, "world_other", "status = 'skipped', reason = 'calls a shell'")
      {:ok, _} = Coverage.store(coverage())

      {:ok, view, _html} = live(conn, ~p"/admin/maintenance")
      assert render_async(view) =~ "Precompiled coverage"

      {:ok, _view, html} = live(conn, ~p"/admin/not-precompiled")
      assert html =~ "Not precompiled"
      refute html =~ name
    end
  end
end
