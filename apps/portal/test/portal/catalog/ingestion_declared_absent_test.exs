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
        hex_latest_version: nil,
        hex_downloads_recent: 398_436,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "ex_money",
        hex_latest_version: nil,
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

    Repo.query!(
      """
      INSERT INTO catalog_module_index_candidates (package, version, generation)
      VALUES ('money', '1.14.0', $1), ('ex_money', '5.24.2', $1)
      """,
      [generation]
    )

    Repo.query!("UPDATE catalog_module_index_runs SET complete = true WHERE generation = $1", [
      generation
    ])

    :ok
  end

  defp toolchain!(observations, lock \\ %{}, inputs \\ []) do
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
        "compile_inputs" => inputs,
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

  # Round 6, R5-6: a pure_elixir result runs the same judge (its
  # host_portability), so the result keeps its record, for the recheck.
  test "a pure_elixir result keeps its declared-absent record" do
    name = "abs_pe_ok_#{System.unique_integer([:positive])}"
    record = %{@money | "declared" => ["ex_money", "money"]}

    result = %{
      "package" => %{"name" => name, "version" => "1.0.0"},
      "finished_at" => "2026-11-21T10:00:00Z",
      "scope" => "full",
      "systems" => %{"pure_elixir" => %{"status" => "pass"}},
      "host_portability" => %{
        "status" => "pass",
        "reason" => nil,
        "portability_rule" => 2,
        "compile_observations" => %{"declared_absent" => [record]}
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

    [sr] =
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id and system_pkg == "pure_elixir")
      |> Ash.read!(domain: @domain)

    assert sr.unpublished_at == nil
    assert sr.declared_absent == [record]
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

  # S10: the worker's module probe inputs, settled at ingest: every popular
  # definer the index shows joins `definers`, and a declared-absent record
  # whose collision the settled input names passes for client 0.10.
  describe "module probe inputs" do
    defp probe(definers),
      do: %{
        "kind" => "probe",
        "of" => "module",
        "name" => "Elixir.Money",
        "answer" => "absent",
        "definers" => definers
      }

    # S10 round 5: a record a probe input carries is that input's, which
    # client 0.10 decides against each user's lock: no refusal, and the
    # input is stored as the worker wrote it (no index definers added).
    test "a probe input carries its record, which no longer refuses" do
      tb = toolchain!(%{"declared_absent" => [@money]}, %{}, [probe(["ex_money"])])

      assert tb.status == :pass
      assert tb.compile_inputs == [probe(["ex_money"])]
    end

    test "a probe input needs no complete index any more" do
      Repo.query!("UPDATE catalog_module_index_runs SET complete = false")
      Repo.query!("DELETE FROM catalog_module_index_packages WHERE package = 'money'")

      tb = toolchain!(%{}, %{}, [probe([])])
      assert tb.status == :pass
      assert tb.compile_inputs == [probe([])]
    end

    # A record no probe input carries (a firmware target's) still refuses.
    test "a record no probe input carries still refuses on a popular definer" do
      tb = toolchain!(%{"declared_absent" => [@money]}, %{}, [])
      assert tb.status == :skipped
      assert tb.reason =~ "also defined by money"
    end

    test "a pure_elixir result's probe input is settled, and its record passes" do
      name = "abs_pe_probe_#{System.unique_integer([:positive])}"

      result = %{
        "package" => %{"name" => name, "version" => "1.0.0"},
        "finished_at" => "2026-11-21T10:00:00Z",
        "scope" => "full",
        "systems" => %{
          "pure_elixir" => %{"status" => "pass", "compile_inputs" => [probe(["ex_money"])]}
        },
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

      [sr] =
        SystemResult
        |> Ash.Query.filter(run_id == ^run.id and system_pkg == "pure_elixir")
        |> Ash.read!(domain: @domain)

      assert sr.unpublished_at == nil
      assert sr.compile_inputs == [probe(["ex_money"])]
    end
  end
end
