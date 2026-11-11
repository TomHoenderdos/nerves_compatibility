defmodule Portal.Workers.ToolchainSweepTest do
  # Not async: the cap tests swap the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package}
  alias Portal.Workers.{Build, ToolchainBuild, ToolchainSweep}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)
    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    %{previous: previous}
  end

  defp put_toolchains(previous, overrides) do
    Application.put_env(:portal, Portal.Toolchains, Keyword.merge(previous, overrides))
  end

  defp one_toolchain(previous, overrides \\ []) do
    put_toolchains(
      previous,
      [images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]] ++ overrides
    )
  end

  # A full worker run of `name` `version`: no carried systems, finished at
  # `finished_at`, host compile with `host` status.
  defp run!(name, version, opts \\ []) do
    finished_at = Keyword.get(opts, :finished_at, ~U[2026-10-20 10:00:00Z])
    run_id = "run-#{name}-#{version}-#{System.unique_integer([:positive])}"

    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{
            "name" => name,
            "version" => version,
            "native_components" => Keyword.get(opts, :native, @pure)
          },
          "finished_at" => DateTime.to_iso8601(finished_at),
          "systems" => %{"host" => %{"status" => Keyword.get(opts, :host, "pass")}}
        },
        %{
          package: name,
          version: version,
          run_id: run_id,
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )

    run_id
  end

  # A bulk-intake registry assessment of `name` `version`: one `registry_deps`
  # system and nothing compiled, as `Portal.Catalog.RegistryAssessment` records
  # it, with `status` and `native` to vary what the catalog shows.
  defp registry_run!(name, version, opts \\ []) do
    finished_at = Keyword.get(opts, :finished_at, ~U[2026-10-20 10:00:00Z])
    run_id = "registry-#{name}-#{version}-#{System.unique_integer([:positive])}"

    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{
            "name" => name,
            "version" => version,
            "native_components" =>
              Keyword.get(opts, :native, %{"compatibility_basis" => "registry_deps"})
          },
          "finished_at" => DateTime.to_iso8601(finished_at),
          "systems" => %{"registry_deps" => %{"status" => Keyword.get(opts, :status, "pass")}}
        },
        %{
          package: name,
          version: version,
          run_id: run_id,
          image_digest: Portal.Catalog.RegistryAssessment.image_digest(),
          files_dir: System.tmp_dir!()
        }
      )

    run_id
  end

  defp package_id!(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Map.fetch!(:id)
  end

  defp toolchain_row!(name, version, status, opts \\ []) do
    row =
      Portal.Catalog.ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: package_id!(name),
        version: version,
        toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
        builder_version: Keyword.get(opts, :builder_version, 1),
        status: status,
        compile_env_rule: Keyword.get(opts, :compile_env_rule, 1),
        run_id: Keyword.get(opts, :run_id, "tc-row"),
        compile_env: Keyword.get(opts, :compile_env, []),
        deps_lock: Keyword.get(opts, :deps_lock),
        config_variant: Keyword.get(opts, :config_variant, "default"),
        reason: Keyword.get(opts, :reason),
        judge_revision: Keyword.get(opts, :judge_revision),
        finished_at: Keyword.get(opts, :finished_at, DateTime.utc_now())
      })
      |> Ash.create!(domain: Catalog)

    if Keyword.get(opts, :revoked, false) do
      row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    else
      row
    end
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  @day 86_400

  describe "Catalog.toolchain_backlog/3" do
    test "lists exactly the versions without a live build" do
      run!("wanted", "1.0.0")
      run!("passed", "1.0.0")
      toolchain_row!("passed", "1.0.0", :pass, finished_at: ago(30 * @day))
      run!("skipped", "1.0.0")
      toolchain_row!("skipped", "1.0.0", :skipped, finished_at: ago(30 * @day))
      run!("old_error", "1.0.0")
      toolchain_row!("old_error", "1.0.0", :error, finished_at: ago(2 * @day))
      run!("fresh_error", "1.0.0")
      toolchain_row!("fresh_error", "1.0.0", :error, finished_at: ago(3600))
      run!("old_fail", "1.0.0")
      toolchain_row!("old_fail", "1.0.0", :fail, finished_at: ago(8 * @day))
      run!("fresh_fail", "1.0.0")
      toolchain_row!("fresh_fail", "1.0.0", :fail, finished_at: ago(2 * @day))
      run!("revoked_row", "1.0.0")

      toolchain_row!("revoked_row", "1.0.0", :error,
        finished_at: ago(30 * @day),
        revoked: true
      )

      run!("nif", "1.0.0", native: %{"nif_language" => "c", "port_languages" => []})
      run!("port", "1.0.0", native: %{"nif_language" => nil, "port_languages" => ["c"]})
      run!("no_native", "1.0.0", native: nil)
      run!("host_failed", "1.0.0", host: "fail")
      "revoked_run" |> run!("1.0.0") |> Catalog.revoke_run()

      backlog = Catalog.toolchain_backlog("1.19/28", 1, 100)

      assert Enum.sort_by(backlog, & &1.package) == [
               %{
                 package: "no_native",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "old_error",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "old_fail",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "wanted",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "a row for another toolchain or builder version is not live here" do
      run!("other", "1.0.0")
      toolchain_row!("other", "1.0.0", :pass, toolchain: "1.20/29")
      toolchain_row!("other", "1.0.0", :pass, builder_version: 2)

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               %{
                 package: "other",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]

      assert Catalog.toolchain_backlog("1.20/29", 1, 100) == []
      assert Catalog.toolchain_backlog("1.19/28", 2, 100) == []
    end

    # With no demand known anywhere, the newest run comes first, and version
    # breaks a tie between runs that finished together.
    test "without download counts the newest version comes first" do
      for {version, day} <- [{"1.0.0", 1}, {"1.1.0", 2}, {"1.2.0", 3}, {"1.3.0", 4}, {"1.4.0", 5}] do
        run!("many", version,
          finished_at: DateTime.new!(~D[2026-10-01], ~T[00:00:00]) |> DateTime.add(day, :day)
        )
      end

      run!("single", "0.1.0", finished_at: ~U[2026-09-01 00:00:00Z])
      run!("tie", "2.0.0", finished_at: ~U[2026-08-01 00:00:00Z])
      run!("tie", "2.1.0", finished_at: ~U[2026-08-01 00:00:00Z])

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               %{
                 package: "many",
                 version: "1.4.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "many",
                 version: "1.3.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "many",
                 version: "1.2.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "many",
                 version: "1.1.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "many",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "single",
                 version: "0.1.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "tie",
                 version: "2.1.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "tie",
                 version: "2.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]

      assert length(Catalog.toolchain_backlog("1.19/28", 1, 2)) == 2
    end

    test "a version with several runs is listed once" do
      run!("twice", "1.0.0", finished_at: ~U[2026-10-01 00:00:00Z])
      run!("twice", "1.0.0", finished_at: ~U[2026-10-02 00:00:00Z])

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               %{
                 package: "twice",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end
  end

  describe "Catalog.toolchain_backlog/3 with registry assessments" do
    defp wanted(name, version \\ "1.0.0"),
      do: %{
        package: name,
        version: version,
        variant: :with,
        config_variant: "default",
        refresh: false,
        reopen: false,
        backfill: false
      }

    # The bulk intake's registry shortcut never compiles, so a package it
    # assessed has no host result: the toolchain build is its first compile.
    test "a version whose only result is a registry_deps pass is wanted" do
      registry_run!("csv", "3.2.2")

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [wanted("csv", "3.2.2")]
    end

    test "the run RegistryAssessment records is wanted as it stands" do
      {:ok, _run} = Portal.Catalog.RegistryAssessment.record("dotenv", "3.1.0", nil)

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [wanted("dotenv", "3.1.0")]
    end

    test "a registry_deps pass of a package with native components is not wanted" do
      registry_run!("nif", "1.0.0", native: %{"nif_language" => "c", "port_languages" => []})

      registry_run!("port", "1.0.0", native: %{"nif_language" => nil, "port_languages" => ["c"]})

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == []
    end

    test "a registry_deps result that did not pass is not wanted" do
      registry_run!("failed", "1.0.0", status: "fail")
      registry_run!("errored", "1.0.0", status: "error")

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == []
    end

    test "a revoked registry run is not wanted" do
      "revoked" |> registry_run!("1.0.0") |> Catalog.revoke_run()

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == []
    end

    test "a registry-only version with a live build is left out like a host one" do
      registry_run!("built", "1.0.0")
      toolchain_row!("built", "1.0.0", :pass)
      registry_run!("fresh_fail", "1.0.0")
      toolchain_row!("fresh_fail", "1.0.0", :fail, finished_at: ago(2 * @day))
      registry_run!("old_fail", "1.0.0")
      toolchain_row!("old_fail", "1.0.0", :fail, finished_at: ago(8 * @day))

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [wanted("old_fail")]
    end

    test "a version with both a host and a registry pass is listed once" do
      registry_run!("both", "1.0.0", finished_at: ~U[2026-10-01 00:00:00Z])
      run!("both", "1.0.0", finished_at: ~U[2026-10-02 00:00:00Z])

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [wanted("both")]
    end

    # Registry-assessed packages rank on the package's hex.pm recent downloads
    # like any other, so the top of Hex is not buried behind host-built ones.
    test "registry-only and host-built versions rank together, most downloaded first" do
      registry_run!("dialyxir", "1.4.5")
      run!("obscure", "9.0.0", finished_at: ~U[2026-10-30 00:00:00Z])
      registry_run!("countries", "1.6.0")
      run!("middling", "1.0.0")
      registry_run!("unknown", "1.0.0", finished_at: ~U[2026-10-31 00:00:00Z])

      for {name, recent} <- [
            {"dialyxir", 9_000_000},
            {"obscure", 40},
            {"countries", 200_000},
            {"middling", 5_000}
          ] do
        Package
        |> Ash.Query.filter(name == ^name)
        |> Ash.read_one!(domain: Catalog)
        |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
        |> Ash.update!(domain: Catalog)
      end

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               wanted("dialyxir", "1.4.5"),
               wanted("countries", "1.6.0"),
               wanted("middling"),
               wanted("obscure", "9.0.0"),
               wanted("unknown")
             ]
    end

    # `Portal.Workers.ReleaseDownloadsRefresh` asks hex.pm about the same
    # backlog, so registry-only versions get their release counts too.
    test "registry-only versions are ranked for release downloads", %{previous: previous} do
      one_toolchain(previous, builder_version: 1)
      registry_run!("ecto_ulid", "0.3.0")

      Package
      |> Ash.Query.filter(name == "ecto_ulid")
      |> Ash.read_one!(domain: Catalog)
      |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: 100_000})
      |> Ash.update!(domain: Catalog)

      assert Catalog.toolchain_backlog_to_rank(10, 3) == [
               %{package: "ecto_ulid", version: "0.3.0"}
             ]
    end
  end

  describe "Catalog.toolchain_backlog/3 demand order" do
    defp downloads!(name, recent) do
      Package
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(domain: Catalog)
      |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
      |> Ash.update!(domain: Catalog)
    end

    defp release_downloads!(name, version, downloads) do
      Portal.Catalog.ReleaseDownloads
      |> Ash.Changeset.for_create(:upsert, %{
        package: name,
        version: version,
        downloads: downloads,
        fetched_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Catalog)
    end

    defp backlog, do: Catalog.toolchain_backlog("1.19/28", 1, 100)

    # What a fresh project resolves is what users ask for: a popular package's
    # older release before an obscure package's brand new one.
    test "a high-download package's version comes before a low-download package's newer one" do
      run!("popular", "1.0.0", finished_at: ~U[2026-01-01 00:00:00Z])
      run!("obscure", "9.0.0", finished_at: ~U[2026-10-30 00:00:00Z])
      downloads!("popular", 5_000_000)
      downloads!("obscure", 40)

      assert backlog() == [
               %{
                 package: "popular",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "obscure",
                 version: "9.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "within a package, the more downloaded release comes first, whatever its age" do
      run!("jason", "1.4.4", finished_at: ~U[2026-03-01 00:00:00Z])
      run!("jason", "1.4.5", finished_at: ~U[2026-10-01 00:00:00Z])
      run!("jason", "1.5.0-alpha.1", finished_at: ~U[2026-10-20 00:00:00Z])
      downloads!("jason", 1_000_000)
      release_downloads!("jason", "1.4.4", 900_000)
      release_downloads!("jason", "1.4.5", 50_000)
      release_downloads!("jason", "1.5.0-alpha.1", 10)

      assert backlog() == [
               %{
                 package: "jason",
                 version: "1.4.4",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "jason",
                 version: "1.5.0-alpha.1",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # Unknown demand is not zero demand, but it is not known demand either:
    # it goes after every known count, and newest-first among itself.
    test "an unknown package count sorts after every known one, zero included" do
      run!("unknown", "1.0.0", finished_at: ~U[2026-10-30 00:00:00Z])
      run!("zero", "1.0.0", finished_at: ~U[2026-01-01 00:00:00Z])
      run!("some", "1.0.0", finished_at: ~U[2026-01-01 00:00:00Z])
      downloads!("zero", 0)
      downloads!("some", 10)

      assert backlog() == [
               %{
                 package: "some",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "zero",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "unknown",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "within a package, a release with no fetched count sorts after the counted ones" do
      run!("jason", "1.4.3", finished_at: ~U[2026-01-01 00:00:00Z])
      run!("jason", "1.4.4", finished_at: ~U[2026-02-01 00:00:00Z])
      run!("jason", "1.4.5", finished_at: ~U[2026-10-01 00:00:00Z])
      downloads!("jason", 1_000_000)
      release_downloads!("jason", "1.4.3", 5)
      release_downloads!("jason", "1.4.4", nil)

      assert backlog() == [
               %{
                 package: "jason",
                 version: "1.4.3",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "jason",
                 version: "1.4.4",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # Release counts break ties inside a package, never across: a package
    # ranks by its own recent downloads first.
    test "a release count never lifts a version above a more downloaded package" do
      run!("big", "1.0.0", finished_at: ~U[2026-01-01 00:00:00Z])
      run!("small", "1.0.0", finished_at: ~U[2026-01-01 00:00:00Z])
      downloads!("big", 1_000)
      downloads!("small", 10)
      release_downloads!("big", "1.0.0", 1)
      release_downloads!("small", "1.0.0", 1_000_000)

      assert backlog() == [
               %{
                 package: "big",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "small",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # A capped sweep takes the most wanted versions, not an arbitrary slice.
    test "the limit keeps the most wanted versions" do
      for {name, recent} <- [{"a", 1}, {"b", 300}, {"c", 20}, {"d", 4_000}] do
        run!(name, "1.0.0")
        downloads!(name, recent)
      end

      assert Catalog.toolchain_backlog("1.19/28", 1, 2) == [
               %{
                 package: "d",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "b",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # Demand only reorders: a version with a live build stays out however
    # popular it is.
    test "demand never brings back a version that already has a live build" do
      run!("popular", "1.0.0")
      run!("popular", "1.1.0")
      toolchain_row!("popular", "1.1.0", :pass)
      downloads!("popular", 9_000_000)
      release_downloads!("popular", "1.1.0", 9_000_000)

      assert backlog() == [
               %{
                 package: "popular",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end
  end

  describe "Catalog.toolchain_counts/0" do
    test "counts each configured toolchain's rows and backlog", %{previous: previous} do
      put_toolchains(previous, builder_version: 1)
      run!("a", "1.0.0")
      toolchain_row!("a", "1.0.0", :pass)
      run!("b", "1.0.0")
      toolchain_row!("b", "1.0.0", :fail)
      run!("c", "1.0.0")
      toolchain_row!("c", "1.0.0", :error, finished_at: ago(2 * @day))
      run!("d", "1.0.0")
      # An older recipe's row is not this builder version's.
      toolchain_row!("d", "1.0.0", :pass, builder_version: 0)

      assert %{
               "1.19/28" => %{pass: 1, skipped: 0, error: 1, fail: 1, backlog: 2},
               "1.20/29" => %{pass: 0, skipped: 0, error: 0, fail: 0, backlog: 4}
             } = Catalog.toolchain_counts()
    end
  end

  describe "perform/1" do
    test "enqueues one build per backlog entry with the toolchain's image", %{previous: previous} do
      one_toolchain(previous)
      run!("wanted", "1.0.0")
      run!("passed", "1.0.0")
      toolchain_row!("passed", "1.0.0", :pass)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert [job] = all_enqueued(worker: ToolchainBuild)
      assert job.queue == "toolchain"

      assert job.args == %{
               "package" => "wanted",
               "version" => "1.0.0",
               "toolchain" => "1.19/28",
               "image" => "ncc-worker:elixir-1.19-otp-28",
               "builder_version" => 1,
               "variant" => "with",
               "config_variant" => "default"
             }
    end

    test "caps the total at max_per_run, spread over the toolchains", %{previous: previous} do
      put_toolchains(previous, max_per_run: 3)
      for name <- ~w(a b c d), do: run!(name, "1.0.0")

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild)
      assert length(jobs) == 3

      assert jobs
             |> Enum.map(& &1.args["toolchain"])
             |> Enum.frequencies()
             |> Map.values()
             |> Enum.sort() == [1, 2]
    end

    test "a second sweep does not duplicate builds still queued", %{previous: previous} do
      one_toolchain(previous)
      run!("wanted", "1.0.0")

      assert :ok = perform_job(ToolchainSweep, %{})
      assert :ok = perform_job(ToolchainSweep, %{})

      assert [_job] = all_enqueued(worker: ToolchainBuild)
    end

    test "enqueues newest versions first under the cap", %{previous: previous} do
      one_toolchain(previous, max_per_run: 2)

      for {version, day} <- [{"1.0.0", 1}, {"1.1.0", 2}, {"1.2.0", 3}] do
        run!("many", version, finished_at: DateTime.add(~U[2026-10-01 00:00:00Z], day, :day))
      end

      assert :ok = perform_job(ToolchainSweep, %{})

      assert all_enqueued(worker: ToolchainBuild) |> Enum.map(& &1.args["version"]) |> Enum.sort() ==
               ["1.1.0", "1.2.0"]
    end
  end

  describe "perform/1 with builds to refresh" do
    # A served pass row (a recorded lock without a withheld package) that
    # does not record its compile-time config reads, old enough to be rebuilt.
    defp served_unmarked!(name, toolchain) do
      toolchain_row!(name, "1.0.0", :pass,
        toolchain: toolchain,
        compile_env_rule: nil,
        compile_env: nil,
        deps_lock: %{},
        finished_at: ago(30 * @day)
      )
    end

    test "new builds on any toolchain take the cap before refresh rebuilds",
         %{previous: previous} do
      put_toolchains(previous,
        max_per_run: 2,
        images: [
          %{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"},
          %{toolchain: "1.20/29", image: "ncc-worker:local"}
        ]
      )

      for name <- ~w(a b c) do
        run!(name, "1.0.0")
        served_unmarked!(name, "1.19/28")
      end

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild)
      assert length(jobs) == 2
      assert Enum.map(jobs, & &1.args["toolchain"]) == ["1.20/29", "1.20/29"]
      assert Enum.map(jobs, & &1.priority) == [0, 0]
    end

    # `count` new default candidates and `refreshes` served builds to
    # refresh, on the one toolchain.
    defp defaults_and_refreshes!(count, refreshes) do
      for i <- 1..count//1, do: run!("new#{i}", "1.0.0")

      for i <- 1..refreshes//1 do
        run!("stale#{i}", "1.0.0")
        served_unmarked!("stale#{i}", "1.19/28")
      end
    end

    defp tiers_enqueued do
      all_enqueued(worker: ToolchainBuild)
      |> Enum.map(fn job ->
        cond do
          job.args["config_variant"] != "default" -> :named
          job.priority == 3 -> :refresh
          true -> :default
        end
      end)
      |> Enum.frequencies()
    end

    # The top package's twelve releases on hex.pm, oldest first: ten of them
    # are backfill candidates (its newest has a run of its own).
    defp hot_backfill! do
      run!("hot", "1.11.0")
      downloads!("hot", 1_000_000)

      Process.put({Portal.Test.FakeHexDeps, :releases}, %{
        "hot" =>
          for(
            minor <- 0..11,
            do: %{version: "1.#{minor}.0", retired?: false, deps: [], outer_checksum: nil}
          )
      })
    end

    defp enqueued_versions do
      for job <- all_enqueued(worker: ToolchainBuild),
          do: {job.args["package"], job.args["version"]}
    end

    # The review's case: a run full of old releases of the top package still
    # queues a new release of a lower-ranked one.
    test "a new release of a lower-ranked package is queued in a run full of backfill",
         %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      hot_backfill!()
      run!("cold", "2.0.0")
      downloads!("cold", 10)

      assert :ok = perform_job(ToolchainSweep, %{})

      versions = enqueued_versions()
      # 8 slots, 2 of them the refresh reserve that no refresh fills.
      assert length(versions) == 8
      assert {"cold", "2.0.0"} in versions
      assert {"hot", "1.11.0"} in versions
      # The other defaults leave their slots to the backfill.
      assert Enum.count(versions, &match?({"hot", _}, &1)) == 7
    end

    test "backfill takes at most its share of the defaults' slots", %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      hot_backfill!()

      for i <- 1..6 do
        run!("cold#{i}", "1.0.0")
        downloads!("cold#{i}", 10 - i)
      end

      assert :ok = perform_job(ToolchainSweep, %{})

      versions = enqueued_versions()
      # Defaults get 8 - 2 (reserve) = 6 slots, a third of them backfill;
      # the unused reserve then goes to the other defaults left over.
      backfilled =
        Enum.reject(versions, &(&1 in [{"hot", "1.11.0"}] or match?({"cold" <> _, _}, &1)))

      assert length(backfilled) == 2
      assert length(versions) == 8
      assert Enum.count(versions, &match?({"cold" <> _, _}, &1)) == 5
    end

    test "a share the backfill does not fill goes to the other defaults",
         %{previous: previous} do
      one_toolchain(previous, max_per_run: 8, backfill_share: 0.5)
      defaults_and_refreshes!(10, 0)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert tiers_enqueued() == %{default: 8}
    end

    test "a quarter of the cap goes to refreshes when defaults alone exceed it",
         %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      defaults_and_refreshes!(10, 4)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert tiers_enqueued() == %{default: 6, refresh: 2}
    end

    test "without refreshes the defaults take the whole cap", %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      defaults_and_refreshes!(10, 0)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert tiers_enqueued() == %{default: 8}
    end

    test "a reserve the refreshes do not fill goes back to the defaults",
         %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      defaults_and_refreshes!(10, 1)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert tiers_enqueued() == %{default: 7, refresh: 1}
    end

    test "a default backlog shorter than its share leaves the rest to refreshes",
         %{previous: previous} do
      one_toolchain(previous, max_per_run: 8)
      defaults_and_refreshes!(2, 10)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert tiers_enqueued() == %{default: 2, refresh: 6}
    end

    test "the backlog limit does not cut the refreshes off behind the defaults" do
      for i <- 1..3 do
        run!("new#{i}", "1.0.0")
      end

      run!("stale", "1.0.0")
      served_unmarked!("stale", "1.19/28")

      backlog = Catalog.toolchain_backlog("1.19/28", 1, 2)

      assert Enum.count(backlog, & &1.refresh) == 1
      assert Enum.count(backlog, &(not &1.refresh)) == 2
      assert List.last(backlog).package == "stale"
    end

    test "refresh rebuilds are enqueued at priority 3", %{previous: previous} do
      one_toolchain(previous)
      run!("served", "1.0.0")
      served_unmarked!("served", "1.19/28")
      run!("new", "1.0.0")

      assert :ok = perform_job(ToolchainSweep, %{})

      assert all_enqueued(worker: ToolchainBuild)
             |> Map.new(&{&1.args["package"], &1.priority}) == %{"new" => 0, "served" => 3}
    end
  end

  describe "perform/1 with named config variants" do
    # A served pass row that recorded reading every `:phoenix_live_view` key
    # the overlays set, unset.
    defp lv_default!(name) do
      unset =
        :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

      env =
        for key <-
              ~w(debug_attributes debug_heex_annotations enable_expensive_runtime_checks root_tag_attribute),
            do: %{"app" => "phoenix_live_view", "path" => [key], "value" => unset}

      toolchain_row!(name, "1.0.0", :pass,
        run_id: "tc-#{name}",
        compile_env: env,
        deps_lock: %{},
        finished_at: ago(30 * @day)
      )
    end

    # A default candidate, a named candidate's three variants and a refresh
    # on one toolchain.
    defp three_tiers!(previous, overrides \\ []) do
      one_toolchain(previous, overrides)
      Portal.PrecompiledFixtures.drop_legacy_identity_index!()
      run!("stale", "1.0.0")
      served_unmarked!("stale", "1.19/28")
      run!("lvs", "1.0.0")
      lv_default!("lvs")
      run!("new", "1.0.0")
    end

    test "named variants queue before defaults and refreshes, at priority 2",
         %{previous: previous} do
      three_tiers!(previous)

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild) |> Enum.sort_by(& &1.id)

      assert Enum.map(jobs, &{&1.args["package"], &1.args["config_variant"], &1.priority}) ==
               [
                 {"lvs", "phx_prod", 2},
                 {"lvs", "phx_test", 2},
                 {"lvs", "phx_dev", 2},
                 {"new", "default", 0},
                 {"stale", "default", 3}
               ]
    end

    test "the cap takes named variants first, then the refresh reserve before defaults",
         %{previous: previous} do
      # A cap of 4 reserves one slot for refreshes; the named variants take
      # the other three.
      three_tiers!(previous, max_per_run: 4)

      assert :ok = perform_job(ToolchainSweep, %{})

      assert all_enqueued(worker: ToolchainBuild)
             |> Enum.sort_by(& &1.id)
             |> Enum.map(&{&1.args["package"], &1.args["config_variant"]}) ==
               [
                 {"lvs", "phx_prod"},
                 {"lvs", "phx_test"},
                 {"lvs", "phx_dev"},
                 {"stale", "default"}
               ]
    end

    test "a default backlog longer than the cap never pushes out a named variant",
         %{previous: previous} do
      three_tiers!(previous, max_per_run: 5)
      for i <- 1..6, do: run!("more#{i}", "1.0.0")

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild)
      assert length(jobs) == 5

      assert jobs
             |> Enum.filter(&(&1.args["config_variant"] != "default"))
             |> Enum.map(& &1.args["config_variant"])
             |> Enum.sort() == ~w(phx_dev phx_prod phx_test)

      # A quarter of the cap (one slot) stays reserved for the refresh.
      assert Enum.count(jobs, &(&1.args["package"] == "stale")) == 1
    end

    test "named variants come first, then the defaults and the refresh reserve share the rest",
         %{previous: previous} do
      three_tiers!(previous, max_per_run: 8)
      for i <- 1..6, do: run!("more#{i}", "1.0.0")

      for i <- 1..3 do
        run!("old#{i}", "1.0.0")
        served_unmarked!("old#{i}", "1.19/28")
      end

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild) |> Enum.sort_by(& &1.id)

      assert jobs |> Enum.take(3) |> Enum.map(& &1.args["config_variant"]) ==
               ~w(phx_prod phx_test phx_dev)

      assert jobs |> Enum.drop(3) |> Enum.map(& &1.priority) == [0, 0, 0, 3, 3]
    end

    test "a named variant reopened by a judge revision does not jump the cap",
         %{previous: previous} do
      # A cap of 4: one slot reserved for the refresh, two new named
      # variants, one new default. The reopened `phx_prod` waits.
      three_tiers!(previous, max_per_run: 4)
      run!("marker", "1.0.0")

      toolchain_row!("marker", "1.0.0", :pass,
        run_id: "tc-marker",
        deps_lock: %{},
        judge_revision: 1,
        finished_at: ago(3600)
      )

      toolchain_row!("lvs", "1.0.0", :skipped,
        run_id: "tc-lvs-prod",
        config_variant: "phx_prod",
        reason: "nerves-specific source",
        finished_at: ago(30 * @day)
      )

      assert :ok = perform_job(ToolchainSweep, %{})

      assert all_enqueued(worker: ToolchainBuild)
             |> Enum.map(&{&1.args["package"], &1.args["config_variant"]})
             |> Enum.sort() ==
               Enum.sort([
                 {"lvs", "phx_test"},
                 {"lvs", "phx_dev"},
                 {"new", "default"},
                 {"stale", "default"}
               ])
    end

    test "reopened rows take the slots new builds leave free", %{previous: previous} do
      three_tiers!(previous, max_per_run: 8)
      run!("marker", "1.0.0")

      toolchain_row!("marker", "1.0.0", :pass,
        run_id: "tc-marker",
        deps_lock: %{},
        judge_revision: 1,
        finished_at: ago(3600)
      )

      toolchain_row!("lvs", "1.0.0", :skipped,
        run_id: "tc-lvs-prod",
        config_variant: "phx_prod",
        reason: "nerves-specific source",
        finished_at: ago(30 * @day)
      )

      assert :ok = perform_job(ToolchainSweep, %{})

      jobs = all_enqueued(worker: ToolchainBuild) |> Enum.sort_by(& &1.id)

      assert Enum.map(jobs, &{&1.args["package"], &1.args["config_variant"], &1.priority}) ==
               [
                 {"lvs", "phx_test", 2},
                 {"lvs", "phx_dev", 2},
                 {"new", "default", 0},
                 {"stale", "default", 3},
                 {"lvs", "phx_prod", 3}
               ]
    end

    test "a second sweep does not duplicate named variants still queued", %{previous: previous} do
      three_tiers!(previous)

      assert :ok = perform_job(ToolchainSweep, %{})
      assert :ok = perform_job(ToolchainSweep, %{})

      assert length(all_enqueued(worker: ToolchainBuild)) == 5
    end

    test "with the legacy index recreated (a rollback) no named variant is queued",
         %{previous: previous} do
      Portal.PrecompiledFixtures.recreate_legacy_identity_index!()
      one_toolchain(previous)
      run!("lvs", "1.0.0")
      lv_default!("lvs")

      assert :ok = perform_job(ToolchainSweep, %{})

      assert all_enqueued(worker: ToolchainBuild) == []
    end
  end

  describe "uniqueness" do
    test "a toolchain build and a firmware build of one version insert side by side" do
      args = %{
        package: "jason",
        version: "1.4.4",
        toolchain: "1.19/28",
        image: "ncc-worker:elixir-1.19-otp-28",
        builder_version: 1
      }

      assert {:ok, %Oban.Job{conflict?: false}} = args |> ToolchainBuild.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: false}} =
               %{package: "jason", version: "1.4.4", image_digest: "sha256:x"}
               |> Build.new()
               |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: true}} = args |> ToolchainBuild.new() |> Oban.insert()

      # Another toolchain, or another recipe, is another build.
      assert {:ok, %Oban.Job{conflict?: false}} =
               args |> Map.put(:toolchain, "1.20/29") |> ToolchainBuild.new() |> Oban.insert()

      assert {:ok, %Oban.Job{conflict?: false}} =
               args |> Map.put(:builder_version, 2) |> ToolchainBuild.new() |> Oban.insert()
    end
  end
end
