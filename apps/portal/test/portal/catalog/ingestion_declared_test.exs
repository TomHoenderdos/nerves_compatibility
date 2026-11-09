defmodule Portal.Catalog.IngestionDeclaredTest do
  use Portal.DataCase, async: true

  require Ash.Query

  alias Portal.Catalog.{Ingestion, Run, SystemResult, ToolchainBuild}
  alias Portal.Repo

  @domain Portal.Catalog

  @declared [
    %{"app" => "jason", "name" => "jason", "requirement" => "~> 1.0", "optional" => true}
  ]

  defp unique_name, do: "declpkg_#{System.unique_integer([:positive])}"

  defp full_result(name, extra) do
    Map.merge(
      %{
        "package" => %{"name" => name, "version" => "1.0.0"},
        "finished_at" => "2026-10-10T10:00:00Z",
        "scope" => "full",
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      },
      extra
    )
  end

  defp ingest!(result) do
    {:ok, run} =
      Ingestion.ingest(result, %{
        package: result["package"]["name"],
        version: result["package"]["version"],
        run_id: "r-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: System.tmp_dir!()
      })

    Run |> Ash.Query.filter(id == ^run.id) |> Ash.read_one!(domain: @domain)
  end

  defp ingest_full_result!(extra), do: ingest!(full_result(unique_name(), extra))

  defp ingest_toolchain_result!(extra, name \\ unique_name()) do
    result = %{
      "scope" => "toolchain",
      "finished_at" => "2026-10-24T11:00:00Z",
      "package" => %{"name" => name, "version" => "1.4.4"},
      "systems" => %{},
      "toolchain_build" =>
        Map.merge(
          %{
            "status" => "skipped",
            "reason" => "os-specific source",
            "elixir" => "1.19.1",
            "otp" => "28",
            "deps_lock" => %{},
            "package_checksum" => "outer",
            "compile_env" => [],
            "file_manifest" => nil
          },
          extra
        )
    }

    {:ok, tb} =
      Ingestion.ingest_toolchain(result, %{
        package: name,
        version: "1.4.4",
        run_id: "tc-#{System.unique_integer([:positive])}",
        image_digest: "sha256:toolchain",
        files_dir: System.tmp_dir!(),
        output_dir: System.tmp_dir!(),
        toolchain: "1.19/28",
        builder_version: 1
      })

    ToolchainBuild |> Ash.Query.filter(id == ^tb.id) |> Ash.read_one!(domain: @domain)
  end

  test "a run keeps the declared list it reported" do
    run = ingest_full_result!(%{"declared" => @declared})
    assert run.declared == @declared
  end

  test "a run without the key stores nil" do
    run = ingest_full_result!(%{})
    assert run.declared == nil
  end

  test "malformed items are dropped as a whole list, not stored" do
    run = ingest_full_result!(%{"declared" => [%{"app" => 1}]})
    assert run.declared == nil
  end

  test "one malformed item among good ones stores nil" do
    bad = %{"app" => "x", "name" => "x", "requirement" => "~> 1.0", "optional" => "yes"}
    run = ingest_full_result!(%{"declared" => @declared ++ [bad]})
    assert run.declared == nil
  end

  test "a non-list stores nil" do
    run = ingest_full_result!(%{"declared" => %{"jason" => "~> 1.0"}})
    assert run.declared == nil
  end

  # A package with no dependencies declares none; the column then reads as
  # unknown, the same as a run from before it was recorded.
  test "an empty list stores nil" do
    run = ingest_full_result!(%{"declared" => []})
    assert run.declared == nil
  end

  test "extra keys inside an item are stripped" do
    [item] = @declared
    run = ingest_full_result!(%{"declared" => [Map.put(item, "extra", "x")]})
    assert run.declared == @declared
  end

  test "a toolchain build keeps toolchain_build.declared" do
    row = ingest_toolchain_result!(%{"declared" => @declared})
    assert row.declared == @declared
  end

  test "a toolchain build without it, or with a malformed one, stores nil" do
    assert ingest_toolchain_result!(%{}).declared == nil
    assert ingest_toolchain_result!(%{"declared" => nil}).declared == nil
    assert ingest_toolchain_result!(%{"declared" => [%{"app" => "x"}]}).declared == nil
  end

  test "a rebuild of the same toolchain identity replaces declared" do
    name = unique_name()
    first = ingest_toolchain_result!(%{"declared" => @declared}, name)
    assert first.declared == @declared

    second = ingest_toolchain_result!(%{}, name)
    assert second.id == first.id
    assert second.declared == nil
  end

  # A carried system result is described by the run that built it
  # (`carried_from_run_id`), so it keeps that run's declared list even when
  # the carrying run reported none.
  test "a carried system result keeps its builder's declared list" do
    name = unique_name()

    first =
      ingest!(
        full_result(name, %{
          "declared" => @declared,
          "systems" => %{
            "nerves_system_rpi4" => %{"status" => "pass"},
            "nerves_system_bbb" => %{"status" => "pass"}
          }
        })
      )

    second =
      ingest!(%{
        "package" => %{"name" => name, "version" => "1.0.0"},
        "finished_at" => "2026-10-11T10:00:00Z",
        "scope" => "targets",
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      })

    assert second.declared == nil

    carried =
      SystemResult
      |> Ash.Query.filter(run_id == ^second.id and system_pkg == "nerves_system_bbb")
      |> Ash.read_one!(domain: @domain)

    assert carried.carried_from_run_id == first.id

    builder =
      Run
      |> Ash.Query.filter(id == ^carried.carried_from_run_id)
      |> Ash.read_one!(domain: @domain)

    assert builder.declared == @declared
  end

  # The release still running during the deploy window inserts rows without
  # the column; they must still insert, and read back as nil.
  test "rows inserted without the column read as nil" do
    run = ingest_full_result!(%{})
    tb = ingest_toolchain_result!(%{})

    %{rows: [[run_id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_runs
          (id, run_id, package_id, version_tested, image_digest, overall_status,
           inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, '1.0.1', 'sha256:x', 'pass',
                now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        ["old-#{System.unique_integer([:positive])}", Ecto.UUID.dump!(run.package_id)]
      )

    old_run =
      Run
      |> Ash.Query.filter(id == ^Ecto.UUID.cast!(run_id))
      |> Ash.read_one!(domain: @domain)

    assert old_run.declared == nil

    %{rows: [[tb_id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_toolchain_builds
          (id, package_id, version, toolchain, builder_version, variant, config_variant,
           status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, '1.4.5', '1.19/28', 1, 'with', 'default', 'skipped',
                now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [Ecto.UUID.dump!(tb.package_id)]
      )

    old_tb =
      ToolchainBuild
      |> Ash.Query.filter(id == ^Ecto.UUID.cast!(tb_id))
      |> Ash.read_one!(domain: @domain)

    assert old_tb.declared == nil
  end
end
