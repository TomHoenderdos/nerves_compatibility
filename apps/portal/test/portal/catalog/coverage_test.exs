defmodule Portal.Catalog.CoverageTest do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Coverage, Ingestion, Package}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(previous,
        builder_version: 2,
        images: [
          %{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"},
          %{toolchain: "1.20/29", image: "ncc-worker:local"}
        ]
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
  end

  defp package!(name) do
    Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
  end

  # A package in the catalog with `recent` downloads and a run per version.
  defp package!(name, recent, versions) do
    Enum.each(versions, &run!(name, &1))

    name
    |> package!()
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  defp build!(name, version, status, opts \\ []) do
    row =
      Portal.Catalog.ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: package!(name).id,
        version: version,
        toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
        builder_version: Keyword.get(opts, :builder_version, 2),
        status: status,
        variant: Keyword.get(opts, :variant, :with),
        deps_lock: Keyword.get(opts, :deps_lock, %{}),
        finished_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Catalog)

    if Keyword.get(opts, :revoked, false) do
      row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    else
      row
    end
  end

  # Until the real check lands, every build counts as carrying its optional
  # dependencies unless a test says otherwise.
  defp report(opts \\ []) do
    Coverage.report(Keyword.merge([optional_deps_complete?: fn _build -> true end], opts))
  end

  defp toolchain(report, toolchain),
    do: Enum.find(report.toolchains, &(&1.toolchain == toolchain))

  defp gap(row, package), do: Enum.find(row.gaps, &(&1.package == package))

  describe "what counts as covered" do
    test "a passing build of the latest stable version" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :pass)

      row = report() |> toolchain("1.19/28")
      assert %{total: 1, covered: 1, percent: 100.0, gaps: []} = row
    end

    test "each configured toolchain is counted on its own, in configured order" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :pass, toolchain: "1.19/28")

      assert [%{toolchain: "1.19/28", covered: 1}, %{toolchain: "1.20/29", covered: 0}] =
               report().toolchains
    end

    # The newest stable release is what `mix deps.get` resolves to; neither the
    # last version the catalog happened to run nor a release candidate is.
    test "the latest version is the highest stable one seen, by version order" do
      package!("jason", 1_000, ["1.10.0", "2.0.0-rc.1", "1.9.0"])
      build!("jason", "1.9.0", :pass)
      build!("jason", "2.0.0-rc.1", :pass)

      row = report() |> toolchain("1.19/28")
      assert row.covered == 0
      assert %{version: "1.10.0"} = gap(row, "jason")

      build!("jason", "1.10.0", :pass)
      assert %{covered: 1} = report() |> toolchain("1.19/28")
    end

    test "a revoked build is not served, so it does not cover" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :pass, revoked: true)

      row = report() |> toolchain("1.19/28")
      assert row.covered == 0
      assert %{reason: :no_host_build} = gap(row, "jason")
    end

    # Coverage counts what a client gets: the manifest serves every passing,
    # non-revoked build, whichever recipe version made it.
    test "a passing build from an older builder version still covers" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :pass, builder_version: 1)

      assert %{covered: 1, gaps: []} = report() |> toolchain("1.19/28")
    end

    # A newer recipe's failure does not take away the build already served.
    test "a served build covers even when a newer recipe's build of it failed" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :pass, builder_version: 1)
      build!("jason", "1.4.5", :fail, builder_version: 2)

      assert %{covered: 1, gaps: []} = report() |> toolchain("1.19/28")
    end

    test "an older recipe's failure alone is still failed" do
      package!("jason", 1_000, ["1.4.5"])
      build!("jason", "1.4.5", :fail, builder_version: 1)

      assert %{reason: :failed} = report() |> toolchain("1.19/28") |> gap("jason")
    end
  end

  describe "gap reasons" do
    test "no toolchain build of any version is no host build" do
      package!("phoenix", 9_000, ["1.8.1"])

      assert %{package: "phoenix", version: "1.8.1", reason: :no_host_build} =
               report() |> toolchain("1.19/28") |> gap("phoenix")
    end

    test "builds of other versions only is no build for the version" do
      package!("req", 5_000, ["0.7.4", "0.7.5"])
      build!("req", "0.7.4", :pass, builder_version: 1)

      assert %{version: "0.7.5", reason: :no_build_for_version} =
               report() |> toolchain("1.19/28") |> gap("req")
    end

    test "a failed or errored build of the version is failed" do
      package!("broken", 500, ["1.0.0"])
      build!("broken", "1.0.0", :fail)
      package!("flaky", 400, ["1.0.0"])
      build!("flaky", "1.0.0", :error)

      row = report() |> toolchain("1.19/28")
      assert %{reason: :failed} = gap(row, "broken")
      assert %{reason: :failed} = gap(row, "flaky")
      assert row.covered == 0
    end

    # Covered in the first column, a gap in the second: a fresh lock would add
    # an optional dependency the build was made without.
    test "a build without its optional dependencies is no optional-deps build" do
      package!("jason", 1_000, ["1.4.5"])
      with_decimal = build!("jason", "1.4.5", :pass, deps_lock: %{"decimal" => "2.3.0"})
      package!("telemetry", 2_000, ["1.3.0"])
      build!("telemetry", "1.3.0", :pass)

      complete? = fn build -> build.id == with_decimal.id end

      row = report(optional_deps_complete?: complete?) |> toolchain("1.19/28")

      assert %{total: 2, covered: 2, percent: 100.0} = row
      assert %{covered_with_optional: 1, percent_with_optional: 50.0} = row
      assert %{version: "1.3.0", reason: :no_optional_deps_build} = gap(row, "telemetry")
      refute gap(row, "jason")
    end

    # A world build carries the world's members, not the package's optional
    # dependencies, and serves only clients that read `builds_closure`: it
    # covers the version, but never counts in the second column.
    test "a world build covers, and never counts as carrying optional dependencies" do
      package!("phoenix", 1_000, ["1.8.16"])
      build!("phoenix", "1.8.16", :pass, variant: :world_phx)

      row = report() |> toolchain("1.19/28")

      assert %{covered: 1, covered_with_optional: 0} = row
      assert %{reason: :no_optional_deps_build} = gap(row, "phoenix")

      build!("phoenix", "1.8.16", :pass)
      assert %{covered: 1, covered_with_optional: 1} = report() |> toolchain("1.19/28")
    end

    # A package that is not covered at all is not counted again in the second
    # column, and keeps its first reason.
    test "an uncovered package is a gap once, with its own reason" do
      package!("phoenix", 9_000, ["1.8.1"])

      row = report(optional_deps_complete?: fn _ -> false end) |> toolchain("1.19/28")
      assert [%{package: "phoenix", reason: :no_host_build}] = row.gaps
      assert %{covered_with_optional: 0} = row
    end
  end

  describe "which packages" do
    test "the top N by recent downloads, N from config by default" do
      for {name, recent} <- [{"a", 10}, {"b", 3_000}, {"c", 200}] do
        package!(name, recent, ["1.0.0"])
      end

      previous = Application.get_env(:portal, :coverage_top_n)
      Application.put_env(:portal, :coverage_top_n, 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:portal, :coverage_top_n, previous),
          else: Application.delete_env(:portal, :coverage_top_n)
      end)

      row = report() |> toolchain("1.19/28")
      assert row.total == 2
      assert row.gaps |> Enum.map(& &1.package) |> Enum.sort() == ["b", "c"]

      assert %{total: 3} = report(top_n: 5) |> toolchain("1.19/28")
    end

    test "100 packages when nothing is configured" do
      previous = Application.get_env(:portal, :coverage_top_n)
      Application.delete_env(:portal, :coverage_top_n)
      on_exit(fn -> if previous, do: Application.put_env(:portal, :coverage_top_n, previous) end)
      assert report().top_n == 100
    end

    test "a package without a recent download count is not ranked" do
      package!("counted", 5, ["1.0.0"])
      run!("uncounted", "1.0.0")

      assert [%{package: "counted"}] = (report() |> toolchain("1.19/28")).gaps
    end

    # The admin reads the list top down: the gap that costs most users first.
    test "gaps come most downloaded first" do
      for {name, recent} <- [{"mid", 500}, {"top", 9_000}, {"low", 3}] do
        package!(name, recent, ["1.0.0"])
      end

      assert ["top", "mid", "low"] =
               report() |> toolchain("1.19/28") |> Map.fetch!(:gaps) |> Enum.map(& &1.package)
    end

    test "percentages are of the packages ranked, to one decimal" do
      for {name, recent} <- [{"a", 3}, {"b", 2}, {"c", 1}] do
        package!(name, recent, ["1.0.0"])
      end

      build!("a", "1.0.0", :pass)

      assert %{total: 3, covered: 1, percent: 33.3} = report() |> toolchain("1.19/28")
    end

    test "an empty catalog is zero of zero, not a crash" do
      assert %{total: 0, covered: 0, percent: percent, gaps: []} =
               report() |> toolchain("1.19/28")

      assert percent == 0.0
    end
  end

  describe "a version with only skipped builds" do
    # Skipped means the toolchain build judged the package not portable: by
    # design there is no host build, which is not a failure of one.
    test "is no host build" do
      package!("esbuild", 3_000, ["0.10.0"])
      build!("esbuild", "0.10.0", :skipped)

      assert %{reason: :no_host_build} = report() |> toolchain("1.19/28") |> gap("esbuild")
    end
  end

  describe "the optional-deps check" do
    # `repo.hex.pm` as `Portal.HexDeps.releases/2` answers it: jason declares
    # decimal optional, ex_doc optional (dev tooling the worker never adds) and
    # telemetry required.
    defp release(version, deps \\ []),
      do: %{version: version, retired?: false, deps: deps, outer_checksum: nil}

    defp dep(package, requirement, optional),
      do: %{package: package, requirement: requirement, optional: optional, repository: "hexpm"}

    @json_deps [
      %{package: "decimal", requirement: "~> 1.0 or ~> 2.0", optional: true, repository: "hexpm"},
      %{package: "ex_doc", requirement: ">= 0.0.0", optional: true, repository: "hexpm"},
      %{package: "telemetry", requirement: "~> 1.0", optional: false, repository: "hexpm"}
    ]

    defp hex_releases do
      releases = %{
        "decimal" => [release("1.9.0"), release("2.2.0"), release("2.3.0"), release("3.0.0-rc.0")],
        "plain" => [release("1.0.0", [dep("telemetry", "~> 1.0", false)])]
      }

      fn
        "json" <> _ ->
          {:ok, [release("1.4.5", @json_deps)]}

        name ->
          case Map.fetch(releases, name) do
            {:ok, found} -> {:ok, found}
            :error -> {:error, :not_found}
          end
      end
    end

    defp lock(deps) do
      Map.new(deps, fn {name, version} ->
        {Atom.to_string(name), %{"version" => version, "checksum" => "c-#{name}"}}
      end)
    end

    # The real check, not a stand-in: a build counts as "with" only when it
    # holds every declared optional Hex dependency, the worker's never-added
    # tooling aside, at the newest version its requirement allows.
    test "counts a build as with only when it holds each optional dependency at its newest match" do
      package!("json_newest", 400, ["1.4.5"])
      build!("json_newest", "1.4.5", :pass, deps_lock: lock(decimal: "2.3.0", telemetry: "1.3.0"))
      package!("json_stale", 300, ["1.4.5"])
      build!("json_stale", "1.4.5", :pass, deps_lock: lock(decimal: "2.2.0", telemetry: "1.3.0"))
      package!("json_none", 200, ["1.4.5"])
      build!("json_none", "1.4.5", :pass, deps_lock: lock(telemetry: "1.3.0"))
      package!("plain", 100, ["1.0.0"])
      build!("plain", "1.0.0", :pass, deps_lock: lock(telemetry: "1.3.0"))

      row = Coverage.report(hex_releases: hex_releases()) |> toolchain("1.19/28")

      assert %{total: 4, covered: 4, covered_with_optional: 2, percent_with_optional: 50.0} = row
      assert %{reason: :no_optional_deps_build} = gap(row, "json_stale")
      assert %{reason: :no_optional_deps_build} = gap(row, "json_none")
      refute gap(row, "json_newest")
      refute gap(row, "plain")
    end

    test "any served build of the version that holds them is enough" do
      package!("json_two", 400, ["1.4.5"])
      build!("json_two", "1.4.5", :pass, deps_lock: lock(telemetry: "1.3.0"))

      build!("json_two", "1.4.5", :pass,
        builder_version: 1,
        deps_lock: lock(decimal: "2.3.0", telemetry: "1.3.0")
      )

      row = Coverage.report(hex_releases: hex_releases()) |> toolchain("1.19/28")
      assert %{covered_with_optional: 1, gaps: []} = row
    end
  end
end
