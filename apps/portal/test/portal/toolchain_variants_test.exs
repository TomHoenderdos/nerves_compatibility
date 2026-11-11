defmodule Portal.ToolchainVariantsTest do
  # A client asks for a precompiled build whose optional dependencies match its
  # own lock exactly: an application with decimal next to jason needs jason
  # built with decimal loadable, one without needs it built without. So a
  # toolchain build is made per variant: "with" every optional dependency a
  # fresh lock would add, and, for a package that has any, "without" them.
  #
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild, UnrecordedOptionalDeps}
  alias Portal.Workers.{Ingest, ToolchainSweep}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400

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

  defp run!(name, version, opts \\ []) do
    result = %{
      "package" => %{"name" => name, "version" => version, "native_components" => @pure},
      "finished_at" => Keyword.get(opts, :finished_at, "2026-10-20T10:00:00Z"),
      "scope" => Keyword.get(opts, :scope, "full"),
      "systems" => Keyword.get(opts, :systems, %{"host" => %{"status" => "pass"}})
    }

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "run-#{name}-#{version}-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: System.tmp_dir!(),
        package: name,
        version: version
      })

    run
  end

  defp package!(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)

  defp row!(name, version, status, opts) do
    ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package!(name).id,
      version: version,
      toolchain: "1.19/28",
      builder_version: 1,
      variant: Keyword.get(opts, :variant, :with),
      optional_deps: Keyword.get(opts, :optional_deps),
      file_manifest: Keyword.get(opts, :file_manifest),
      status: status,
      reason: Keyword.get(opts, :reason),
      compile_env_rule: Keyword.get(opts, :compile_env_rule, 1),
      run_id: Keyword.get(opts, :run_id, "tc-row"),
      compile_env: Keyword.get(opts, :compile_env, []),
      finished_at: Keyword.get(opts, :finished_at, DateTime.utc_now())
    })
    |> Ash.create!(domain: Catalog)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp backlog, do: Catalog.toolchain_backlog("1.19/28", 1, 100)

  # What the worker reports for a "with" build that kept decimal.
  @kept_decimal %{"added" => ["decimal"], "dropped" => [], "skipped" => [], "reason" => nil}
  @no_optional %{"added" => [], "dropped" => [], "skipped" => [], "reason" => nil}

  describe "a toolchain build per variant" do
    test "with and without are separate builds of one version" do
      run!("jason", "1.4.5")
      with_row = row!("jason", "1.4.5", :pass, variant: :with, optional_deps: @kept_decimal)
      without_row = row!("jason", "1.4.5", :pass, variant: :without, optional_deps: @no_optional)

      refute with_row.id == without_row.id
      assert with_row.variant == :with
      assert without_row.variant == :without
      assert with_row.optional_deps == @kept_decimal
    end

    test "rebuilding a variant replaces that variant's row only" do
      run!("jason", "1.4.5")
      pkg = package!("jason")

      attrs = %{
        package_id: pkg.id,
        version: "1.4.5",
        toolchain: "1.19/28",
        builder_version: 1,
        variant: :without,
        status: :error,
        reason: "timeout"
      }

      with_row = row!("jason", "1.4.5", :pass, variant: :with)

      {:ok, a} =
        ToolchainBuild |> Ash.Changeset.for_create(:upsert, attrs) |> Ash.create(domain: Catalog)

      {:ok, b} =
        ToolchainBuild
        |> Ash.Changeset.for_create(:upsert, %{attrs | status: :pass, reason: nil})
        |> Ash.create(domain: Catalog)

      assert a.id == b.id and b.status == :pass
      assert Ash.get!(ToolchainBuild, with_row.id, domain: Catalog).status == :pass
    end

    # Every row built before variants existed was built the "with" way.
    test "a row written without a variant is a with build" do
      run!("jason", "1.4.5")
      pkg = package!("jason")

      row =
        ToolchainBuild
        |> Ash.Changeset.for_create(:create, %{
          package_id: pkg.id,
          version: "1.4.5",
          toolchain: "1.19/28",
          builder_version: 1,
          status: :pass
        })
        |> Ash.create!(domain: Catalog)

      assert row.variant == :with
    end

    test "ingesting a build records its variant and the optional dependencies it reports" do
      dir = Path.join(System.tmp_dir!(), "variant-files-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      result = %{
        "scope" => "toolchain",
        "finished_at" => "2026-11-01T10:00:00Z",
        "package" => %{"name" => "variantpkg", "version" => "1.0.0"},
        "systems" => %{},
        "requested_optional_deps" => "exclude",
        "optional_deps" => @no_optional,
        "toolchain_build" => %{
          "status" => "skipped",
          "reason" => "nerves-specific source",
          "elixir" => "1.19.1",
          "otp" => "28",
          "deps_lock" => %{},
          "package_checksum" => "outer",
          "compile_env" => [],
          "file_manifest" => nil
        }
      }

      opts = %{
        run_id: "tc-variant",
        image_digest: "sha256:t",
        files_dir: dir,
        output_dir: dir,
        toolchain: "1.19/28",
        builder_version: 1,
        version: "1.0.0",
        variant: :without,
        package: "variantpkg"
      }

      assert {:ok, row} = Ingestion.ingest_toolchain(result, opts)
      assert row.variant == :without
      assert row.optional_deps == @no_optional
    end
  end

  describe "the backlog per variant" do
    test "a version never built is wanted with its optional dependencies first" do
      run!("jason", "1.4.5")

      assert backlog() == [
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # The case that started this: jason 1.4.5 is built with decimal, and an
    # application without decimal still gets no hit.
    test "a with build that kept an optional dependency makes the without build wanted" do
      run!("jason", "1.4.5")
      row!("jason", "1.4.5", :pass, variant: :with, optional_deps: @kept_decimal)

      assert backlog() == [
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :without,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "a package without optional dependencies is built once" do
      run!("telemetry", "1.3.0")
      row!("telemetry", "1.3.0", :pass, variant: :with, optional_deps: @no_optional)

      assert backlog() == []
    end

    test "a version with both variants built is done" do
      run!("jason", "1.4.5")
      row!("jason", "1.4.5", :pass, variant: :with, optional_deps: @kept_decimal)
      row!("jason", "1.4.5", :pass, variant: :without, optional_deps: @no_optional)

      assert backlog() == []
    end

    test "each variant's own row decides whether it is live" do
      run!("jason", "1.4.5")
      row!("jason", "1.4.5", :pass, variant: :with, optional_deps: @kept_decimal)
      row!("jason", "1.4.5", :fail, variant: :without, finished_at: ago(2 * @day))

      assert backlog() == []
    end
  end

  describe "a with build whose optional dependencies were dropped" do
    defp dropped(reason),
      do: %{"added" => [], "dropped" => ["decimal"], "skipped" => [], "reason" => reason}

    # The pass row would otherwise stand for a "with" build forever. But a
    # drop that happens the same way every time must not be rebuilt every day:
    # it comes back after a week, or when the recipe changed.
    test "is built again a week after its last attempt" do
      for {reason, name} <- [{"deps_get_failed", "dropa"}, {"timeout", "dropb"}] do
        run!(name, "1.0.0")

        row!(name, "1.0.0", :pass,
          variant: :with,
          optional_deps: dropped(reason),
          finished_at: ago(7 * @day + 3600)
        )
      end

      assert Enum.sort_by(backlog(), & &1.package) == [
               %{
                 package: "dropa",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               },
               %{
                 package: "dropb",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "is not built again within the week" do
      for {age, name} <- [{3600, "hour"}, {2 * @day, "days"}, {7 * @day - 3600, "almost"}] do
        run!(name, "1.0.0")

        row!(name, "1.0.0", :pass,
          variant: :with,
          optional_deps: dropped("deps_get_failed"),
          finished_at: ago(age)
        )
      end

      assert backlog() == []
    end

    # A new recipe is a new build: nothing about the old attempt carries over,
    # however recent it was.
    test "is built again at once by a new builder version" do
      run!("jason", "1.4.5")

      row!("jason", "1.4.5", :pass,
        variant: :with,
        optional_deps: dropped("deps_get_failed"),
        finished_at: ago(3600)
      )

      assert Catalog.toolchain_backlog("1.19/28", 2, 100) == [
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # A compile failure with decimal loadable is a verdict: within the week it
    # is not retried either.
    test "a verdict reason is not built again within the week" do
      run!("jason", "1.4.5")

      row!("jason", "1.4.5", :pass,
        variant: :with,
        optional_deps: dropped("host_compile_failed"),
        finished_at: ago(2 * @day)
      )

      assert backlog() == []
    end
  end

  describe "liveness judged on the host result itself" do
    # A targets or argus-only run carries the other systems from the run
    # before it. Its own host compile is fresh evidence and must count.
    test "a run whose own host passed counts, even when it carried other systems" do
      run!("starved", "1.0.0",
        systems: %{"host" => %{"status" => "fail"}, "nerves_system_rpi4" => %{"status" => "pass"}}
      )

      run!("starved", "1.0.0",
        scope: "argus_only",
        finished_at: "2026-10-21T10:00:00Z",
        systems: %{"host" => %{"status" => "pass"}}
      )

      assert backlog() == [
               %{
                 package: "starved",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    # A host result copied from a revoked run is not evidence of anything.
    # (A guard: it holds before and after the change.)
    test "a host result carried from a revoked run does not count" do
      first =
        run!("carried", "1.0.0",
          systems: %{
            "host" => %{"status" => "pass"},
            "nerves_system_rpi4" => %{"status" => "pass"}
          }
        )

      run!("carried", "1.0.0",
        scope: "targets",
        finished_at: "2026-10-21T10:00:00Z",
        systems: %{"nerves_system_rpi4" => %{"status" => "pass"}}
      )

      Catalog.revoke_run(first.run_id)

      assert backlog() == []
    end
  end

  describe "packages skipped for shipping priv files" do
    # Static priv data is portable now. The stored verdict is not flipped:
    # the version is built again, and that build decides.
    test "are built again" do
      run!("withpriv", "1.0.0")
      row!("withpriv", "1.0.0", :skipped, reason: "ships priv files", finished_at: ago(8 * @day))

      assert backlog() == [
               %{
                 package: "withpriv",
                 version: "1.0.0",
                 variant: :with,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "any other skip reason stays a verdict" do
      run!("shellout", "1.0.0")
      row!("shellout", "1.0.0", :skipped, reason: "calls System.cmd/3")

      assert backlog() == []
    end

    test "the sweep queues the build and leaves the stored row alone" do
      run!("withpriv", "1.0.0")

      row =
        row!("withpriv", "1.0.0", :skipped,
          reason: "ships priv files",
          finished_at: ago(8 * @day)
        )

      assert :ok = perform_job(ToolchainSweep, %{})

      assert_enqueued(
        worker: Portal.Workers.ToolchainBuild,
        args: %{"package" => "withpriv", "version" => "1.0.0", "variant" => "with"}
      )

      stored = Ash.get!(ToolchainBuild, row.id, domain: Catalog)
      assert stored.status == :skipped
      assert stored.reason == "ships priv files"
    end
  end

  describe "enqueueing variants" do
    test "with goes ahead of without in the queue" do
      run!("jason", "1.4.5")
      row!("jason", "1.4.5", :pass, variant: :with, optional_deps: @kept_decimal)
      run!("decimal", "2.3.0")

      assert :ok = perform_job(ToolchainSweep, %{})

      [without] =
        all_enqueued(worker: Portal.Workers.ToolchainBuild)
        |> Enum.filter(&(&1.args["package"] == "jason"))

      [with] =
        all_enqueued(worker: Portal.Workers.ToolchainBuild)
        |> Enum.filter(&(&1.args["package"] == "decimal"))

      assert without.args["variant"] == "without"
      assert with.args["variant"] == "with"
      assert with.priority < without.priority
    end

    test "the two variants of one version are separate jobs, each unique" do
      args = %{
        "package" => "jason",
        "version" => "1.4.5",
        "toolchain" => "1.19/28",
        "image" => "ncc-worker:elixir-1.19-otp-28",
        "builder_version" => 1
      }

      assert {:ok, %{conflict?: false}} =
               Oban.insert(Portal.Workers.ToolchainBuild.new(Map.put(args, "variant", "with")))

      assert {:ok, %{conflict?: false}} =
               Oban.insert(Portal.Workers.ToolchainBuild.new(Map.put(args, "variant", "without")))

      assert {:ok, %{conflict?: true}} =
               Oban.insert(Portal.Workers.ToolchainBuild.new(Map.put(args, "variant", "without")))
    end
  end

  describe "building a variant" do
    defmodule VariantBuilder do
      def build(args, _opts \\ []) do
        send(self(), {:build_args, args})

        {:ok,
         %{
           exit_code: 0,
           result: %{"toolchain_build" => %{"status" => "pass"}},
           files_dir: "/scratch/files",
           output_dir: "/scratch/out",
           log: ""
         }}
      end

      def cleanup(_run_id), do: :ok
      def image_digest(_image), do: "sha256:toolchain-image"
    end

    setup do
      Application.put_env(:portal, :build_runner, VariantBuilder)
      on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
      :ok
    end

    @job_args %{
      "package" => "jason",
      "version" => "1.4.5",
      "toolchain" => "1.19/28",
      "image" => "ncc-worker:elixir-1.19-otp-28",
      "builder_version" => 1
    }

    test "with runs the optional dependencies pass, without leaves it out" do
      for {variant, expected} <- [{"with", "include"}, {"without", "exclude"}] do
        assert :ok =
                 perform_job(
                   Portal.Workers.ToolchainBuild,
                   Map.put(@job_args, "variant", variant)
                 )

        assert_received {:build_args, %{optional_deps: ^expected}}
      end
    end

    test "the ingest is told which variant it records" do
      assert :ok =
               perform_job(
                 Portal.Workers.ToolchainBuild,
                 Map.put(@job_args, "variant", "without")
               )

      assert_enqueued(worker: Ingest, args: %{"kind" => "toolchain", "variant" => "without"})
    end

    # Jobs queued before variants existed carry none: they were with builds.
    test "a job without a variant builds with" do
      assert :ok = perform_job(Portal.Workers.ToolchainBuild, @job_args)
      assert_received {:build_args, %{optional_deps: "include"}}
    end
  end

  # Rows written before builds recorded their optional dependencies say
  # nothing about them. The registry does: a package that declares one
  # still needs its without build.
  describe "a with build from before optional dependencies were recorded" do
    defp declares(name, deps) do
      releases = [%{version: "1.4.5", retired?: false, deps: deps, outer_checksum: nil}]
      current = Process.get({Portal.Test.FakeHexDeps, :releases}, %{})
      Process.put({Portal.Test.FakeHexDeps, :releases}, Map.put(current, name, releases))
    end

    defp dep(package, optional),
      do: %{package: package, requirement: ">= 0.0.0", optional: optional, repository: "hexpm"}

    test "gets a without build when the package declares an optional Hex dependency" do
      run!("jason", "1.4.5")
      row!("jason", "1.4.5", :pass, variant: :with, optional_deps: nil)
      declares("jason", [dep("decimal", true), dep("telemetry", false)])

      assert backlog() == [
               %{
                 package: "jason",
                 version: "1.4.5",
                 variant: :without,
                 config_variant: "default",
                 refresh: false,
                 reopen: false,
                 backfill: false
               }
             ]
    end

    test "gets none when the package declares no optional dependency" do
      run!("plain", "1.4.5")
      row!("plain", "1.4.5", :pass, variant: :with, optional_deps: nil)
      declares("plain", [dep("telemetry", false)])

      assert backlog() == []
    end

    # Dev tooling the worker never adds would make a without build identical
    # to the with build.
    test "gets none when its only optional dependencies are ones never added" do
      run!("tooled", "1.4.5")
      row!("tooled", "1.4.5", :pass, variant: :with, optional_deps: nil)
      declares("tooled", [dep("ex_doc", true), dep("credo", true)])

      assert backlog() == []
    end

    # Only the most downloaded unrecorded packages are asked about per call.
    # A version the registry shows declares nothing to add is recorded as
    # such, so it leaves the set and the packages behind it get their turn.
    test "one that declares nothing to add makes room for the next package" do
      for i <- 0..200 do
        name = "legacy_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        run!(name, "1.4.5")

        Repo.query!("UPDATE catalog_packages SET hex_downloads_recent = $1 WHERE name = $2", [
          10_000 - i,
          name
        ])

        row!(name, "1.4.5", :pass,
          variant: :with,
          optional_deps: nil,
          file_manifest: %{"lib/#{name}.beam" => "sha256:#{i}"},
          finished_at: ago(3 * @day)
        )

        declares(name, [dep(if(i == 200, do: "decimal", else: "telemetry"), i == 200)])
      end

      before = legacy_rows()

      wanted = Enum.flat_map(1..2, fn _ -> backlog() end)

      assert %{
               package: "legacy_200",
               version: "1.4.5",
               variant: :without,
               config_variant: "default",
               refresh: false,
               reopen: false,
               backfill: false
             } in wanted

      after_rows = legacy_rows()

      for {name, row} <- before, name != "legacy_200" do
        recorded = Map.fetch!(after_rows, name)
        assert recorded.optional_deps == %{"added" => [], "reason" => "unrecorded_none"}
        assert recorded.status == row.status
        assert DateTime.compare(recorded.finished_at, row.finished_at) == :eq
        assert recorded.file_manifest == row.file_manifest
        assert recorded.revoked_at == row.revoked_at
      end

      assert Map.fetch!(after_rows, "legacy_200").optional_deps ==
               %{"added" => ["decimal"], "reason" => "unrecorded_declared"}
    end

    # Many packages do not compile without their optional dependencies, so
    # their without build fails for good. A version the registry shows
    # declares one is recorded on its with row after one look, which hands it
    # to the backlog's own rule for a recorded `added` (a failed without
    # build again after a week) and takes it out of the set the registry is
    # asked about, so the packages behind it get their turn.
    test "one that declares a dependency to add is asked about once" do
      for i <- 0..200 do
        name = "legacy_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        run!(name, "1.4.5")

        Repo.query!("UPDATE catalog_packages SET hex_downloads_recent = $1 WHERE name = $2", [
          10_000 - i,
          name
        ])

        row!(name, "1.4.5", :pass,
          variant: :with,
          optional_deps: nil,
          file_manifest: %{"lib/#{name}.beam" => "sha256:#{i}"},
          finished_at: ago(3 * @day)
        )

        row!(name, "1.4.5", :fail, variant: :without, finished_at: ago(@day))
      end

      test_pid = self()

      hex_releases = fn name ->
        send(test_pid, {:asked, name})

        {:ok,
         [
           %{
             version: "1.4.5",
             retired?: false,
             deps: [dep("decimal", true), dep("ex_doc", true), dep("telemetry", false)]
           }
         ]}
      end

      before = legacy_with_rows()

      UnrecordedOptionalDeps.wanted("1.19/28", 1, hex_releases: hex_releases)
      refute_received {:asked, "legacy_200"}
      flush_asked()

      UnrecordedOptionalDeps.wanted("1.19/28", 1, hex_releases: hex_releases)
      assert_received {:asked, "legacy_200"}
      refute_received {:asked, "legacy_000"}

      after_rows = legacy_with_rows()

      for {name, row} <- before do
        recorded = Map.fetch!(after_rows, name)

        assert recorded.optional_deps == %{
                 "added" => ["decimal"],
                 "reason" => "unrecorded_declared"
               }

        assert recorded.status == row.status
        assert DateTime.compare(recorded.finished_at, row.finished_at) == :eq
        assert recorded.file_manifest == row.file_manifest
      end

      # The failed without build is a verdict for its week, then wanted again
      # by the recorded `added`, without asking the registry.
      refute Enum.any?(backlog(), &(&1.variant == :without))

      Repo.query!(
        "UPDATE catalog_toolchain_builds SET finished_at = $1 WHERE variant = 'without'",
        [ago(8 * @day)]
      )

      assert %{
               package: "legacy_000",
               version: "1.4.5",
               variant: :without,
               config_variant: "default",
               refresh: false,
               reopen: false,
               backfill: false
             } in backlog()
    end

    # A registry that cannot answer says nothing about the version: the row
    # stays unrecorded and is asked about again.
    test "stays unrecorded when the registry does not answer" do
      run!("unlisted", "1.4.5")
      row!("unlisted", "1.4.5", :pass, variant: :with, optional_deps: nil)

      assert backlog() == []
      assert [%{optional_deps: nil}] = Map.values(legacy_rows())
    end

    # A build that lands while the registry is asked keeps its own report.
    test "a row recorded meanwhile is not overwritten" do
      run!("plain", "1.4.5")
      row!("plain", "1.4.5", :pass, variant: :with, optional_deps: nil)

      hex_releases = fn "plain" ->
        Repo.query!("UPDATE catalog_toolchain_builds SET optional_deps = $1", [@kept_decimal])
        {:ok, [%{version: "1.4.5", retired?: false, deps: [dep("telemetry", false)]}]}
      end

      assert UnrecordedOptionalDeps.wanted("1.19/28", 1, hex_releases: hex_releases) ==
               {[], []}

      assert [%{optional_deps: @kept_decimal}] = Map.values(legacy_rows())
    end

    defp flush_asked do
      receive do
        {:asked, _name} -> flush_asked()
      after
        0 -> :ok
      end
    end

    defp legacy_with_rows do
      ToolchainBuild
      |> Ash.Query.filter(variant == :with)
      |> Ash.Query.load(:package)
      |> Ash.read!(domain: Catalog)
      |> Map.new(&{&1.package.name, &1})
    end

    defp legacy_rows do
      ToolchainBuild
      |> Ash.Query.load(:package)
      |> Ash.read!(domain: Catalog)
      |> Map.new(&{&1.package.name, &1})
    end
  end

  # A re-opened identity comes back once a week at most: a rebuild that
  # fails again must not put it back in every sweep.
  describe "a re-opened identity" do
    defmodule FailingBuilder do
      def build(_args, _opts \\ []) do
        {:ok,
         %{
           exit_code: 10,
           result: nil,
           files_dir: "/scratch/files",
           output_dir: "/scratch/out",
           log: "boom"
         }}
      end

      def cleanup(_run_id), do: :ok
      def image_digest(_image), do: "sha256:toolchain-image"
    end

    setup do
      Application.put_env(:portal, :build_runner, FailingBuilder)
      on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
      :ok
    end

    defp fail_last_attempt(package, version) do
      args = %{
        "package" => package,
        "version" => version,
        "toolchain" => "1.19/28",
        "image" => "ncc-worker:elixir-1.19-otp-28",
        "builder_version" => 1,
        "variant" => "with"
      }

      ExUnit.CaptureLog.capture_log(fn ->
        perform_job(Portal.Workers.ToolchainBuild, args, attempt: 2)
      end)
    end

    test "a priv skip is not re-opened within the week" do
      run!("fresh", "1.0.0")
      row!("fresh", "1.0.0", :skipped, reason: "ships priv files", finished_at: ago(2 * @day))

      assert backlog() == []
    end

    test "a priv skip whose rebuild fails stays out for the week" do
      run!("withpriv", "1.0.0")
      row!("withpriv", "1.0.0", :skipped, reason: "ships priv files", finished_at: ago(30 * @day))
      assert [%{package: "withpriv"}] = backlog()

      fail_last_attempt("withpriv", "1.0.0")

      assert backlog() == []
    end

    # The manifest serves finished_at as the build's date: a retry that kept
    # the old row must not make an old build look new. The attempt is
    # recorded on its own.
    test "a kept row's finished_at is unchanged by the failed retry" do
      run!("withpriv", "1.0.0")
      finished_at = ago(30 * @day)
      row!("withpriv", "1.0.0", :skipped, reason: "ships priv files", finished_at: finished_at)

      fail_last_attempt("withpriv", "1.0.0")

      assert [row] =
               Portal.Catalog.ToolchainBuild
               |> Ash.read!(domain: Portal.Catalog)
               |> Enum.filter(&(&1.version == "1.0.0" and &1.status == :skipped))

      assert DateTime.compare(row.finished_at, finished_at) == :eq
      assert DateTime.diff(DateTime.utc_now(), row.attempted_at) < 60
    end

    test "a dropped with build whose rebuild fails stays out for the week" do
      run!("jason", "1.4.5")

      row!("jason", "1.4.5", :pass,
        variant: :with,
        optional_deps: %{
          "added" => [],
          "dropped" => ["decimal"],
          "skipped" => [],
          "reason" => "timeout"
        },
        finished_at: ago(30 * @day)
      )

      assert [%{package: "jason", variant: :with, config_variant: "default", refresh: false}] =
               backlog()

      fail_last_attempt("jason", "1.4.5")

      assert backlog() == []
    end
  end
end
