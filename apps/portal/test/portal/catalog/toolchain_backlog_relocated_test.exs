defmodule Portal.Catalog.ToolchainBacklogRelocatedTest do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @env [%{"app" => "demo", "key" => "mode", "value" => "x"}]
  @manifest %{"ebin" => [%{"path" => "ebin/demo.beam", "sha256" => "a"}], "priv" => []}

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

  # A pass row with the R5 mark, so only the rule under test can reopen it.
  defp row!(name, opts) do
    run!(name, "1.0.0")
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)

    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: "1.0.0",
      toolchain: "1.19/28",
      builder_version: 1,
      status: :pass,
      deps_lock: %{},
      compile_env_rule: 1,
      compile_env: @env,
      run_id: "tc-#{name}",
      relocation: Keyword.get(opts, :relocation),
      relocated_file_manifest: Keyword.get(opts, :relocated_file_manifest),
      file_manifest: Keyword.get(opts, :file_manifest),
      finished_at: Keyword.get(opts, :finished_at, ago(30 * @day))
    })
    |> Ash.create!(domain: Catalog)
  end

  defp relocated!(name, opts \\ []) do
    row!(
      name,
      [
        relocation: Portal.Test.RelocationFixtures.record("demo"),
        relocated_file_manifest: @manifest
      ] ++ opts
    )
  end

  # A release before S4 ingests a relocated result: it reads `file_manifest`
  # alone (nil), writes its own run and R5 mark, and leaves the relocation
  # columns it does not know.
  defp old_release_ingest!(row) do
    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run', " <>
        "compile_env_run_id = 'old-release-run', file_manifest = NULL WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp names, do: "1.19/28" |> Catalog.toolchain_backlog(1, 100) |> Enum.map(& &1.package)

  test "a relocated pass whose record counts is judged, not rebuilt" do
    row = relocated!("moved")
    assert row.relocation_run_id == row.run_id
    assert row.file_manifest == nil

    row!("plain", file_manifest: @manifest)

    assert names() == []
  end

  # Review N1: an old build node's ingest leaves a pass that serves nothing,
  # neither as a plain build nor as a relocated one.
  test "a pass an old release stored with no files is rebuilt once due" do
    "stranded" |> relocated!() |> old_release_ingest!()
    "never_relocated" |> row!(file_manifest: @manifest) |> old_release_ingest!()

    assert Enum.sort(names()) == ["never_relocated", "stranded"]
  end

  test "a pass with no files is not rebuilt within a week of its build" do
    "fresh" |> relocated!(finished_at: ago(2 * @day)) |> old_release_ingest!()
    assert names() == []
  end
end
