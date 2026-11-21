defmodule Portal.Catalog.IngestionDeclaredAbsentTest do
  # Round 3, R2-1: ingest refuses a pass build whose judge recorded a
  # declared-absent probe of a module another popular package defines
  # (`Portal.Catalog.ModuleIndex`).
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{Ingestion, Run, SystemResult, ToolchainBuild}

  @domain Portal.Catalog

  @money %{
    "kind" => "module_absent",
    "module" => "Elixir.Money",
    "declared" => ["ex_money"],
    "via" => "Code.ensure_loaded?/1"
  }

  setup do
    now = NaiveDateTime.utc_now()

    Repo.insert_all("catalog_packages", [
      %{
        name: "money",
        hex_latest_version: "1.14.0",
        hex_downloads_recent: 398_436,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "ex_money",
        hex_latest_version: "5.24.2",
        hex_downloads_recent: 302_825,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("catalog_module_definers", [
      %{module: "Elixir.Money", package: "money"},
      %{module: "Elixir.Money", package: "ex_money"}
    ])

    # A complete run (generation) that confirmed both candidates.
    {:ok, generation} = Portal.Catalog.ModuleIndex.start_run(2)

    Repo.query!(
      """
      INSERT INTO catalog_module_index_packages (package, version, modules, refreshed_at, generation, app)
      VALUES ('money', '1.14.0', 1, now(), $1, 'money'), ('ex_money', '5.24.2', 1, now(), $1, 'ex_money')
      """,
      [generation]
    )

    Repo.query!("UPDATE catalog_module_index_runs SET complete = true WHERE generation = $1", [
      generation
    ])

    :ok
  end

  defp toolchain!(observations, lock \\ %{}) do
    name = "abs_#{System.unique_integer([:positive])}"

    result = %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-21T11:00:00Z",
      "package" => %{"name" => name, "version" => "1.1.1"},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => "1.20.3",
        "otp" => "29",
        "deps_lock" => lock,
        "package_checksum" => "outer",
        "compile_env" => [],
        "compile_inputs" => [],
        "file_manifest" => nil,
        "compile_observations" => observations
      }
    }

    {:ok, tb} =
      Ingestion.ingest_toolchain(result, %{
        package: name,
        version: "1.1.1",
        run_id: "tc-#{System.unique_integer([:positive])}",
        image_digest: "sha256:toolchain",
        files_dir: System.tmp_dir!(),
        output_dir: System.tmp_dir!(),
        toolchain: "1.20/29",
        builder_version: 1
      })

    ToolchainBuild |> Ash.Query.filter(id == ^tb.id) |> Ash.read_one!(domain: @domain)
  end

  test "a toolchain build with a colliding declared-absent probe is stored skipped" do
    tb = toolchain!(%{"declared_absent" => [@money]})
    assert tb.status == :skipped

    assert tb.reason ==
             "compile-time probe of a dependency outside the closure: Elixir.Money via " <>
               "Code.ensure_loaded?/1 (also defined by money)"

    assert tb.compile_observations["declared_absent"] == [@money]
  end

  test "no collision, or the other definer locked: the build passes" do
    assert toolchain!(%{"declared_absent" => [%{@money | "declared" => ["ex_money", "money"]}]}).status ==
             :pass

    lock = %{"money" => %{"version" => "1.14.0", "checksum" => String.duplicate("a", 64)}}
    assert toolchain!(%{"declared_absent" => [@money]}, lock).status == :pass
    assert toolchain!(%{}).status == :pass
  end

  test "a pure_elixir result with a colliding probe is held back, unpublished" do
    name = "abs_pe_#{System.unique_integer([:positive])}"

    result = %{
      "package" => %{"name" => name, "version" => "1.0.0"},
      "finished_at" => "2026-11-21T10:00:00Z",
      "scope" => "full",
      "systems" => %{"pure_elixir" => %{"status" => "pass"}},
      "host_portability" => %{
        "status" => "pass",
        "reason" => nil,
        "portability_rule" => 2,
        "compile_observations" => %{"declared_absent" => [@money]}
      }
    }

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: name,
        version: "1.0.0",
        run_id: "r-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: System.tmp_dir!()
      })

    run = Run |> Ash.Query.filter(id == ^run.id) |> Ash.read_one!(domain: @domain)

    [sr] =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id and system_pkg == "pure_elixir")
      |> Ash.read!(domain: @domain)

    assert sr.unpublished_at != nil

    assert sr.unpublished_reason =~
             "Elixir.Money via Code.ensure_loaded?/1 (also defined by money)"
  end
end
