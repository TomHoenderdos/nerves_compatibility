defmodule Portal.Catalog.LatestRunTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, LatestRun, Package, Run, SystemResult}
  alias Portal.Workers.Build

  describe "supersedes?/2" do
    test "a higher version, the same one, or a first one becomes the latest" do
      assert LatestRun.supersedes?("0.6.10", "0.6.9")
      assert LatestRun.supersedes?("0.6.10", "0.6.10")
      assert LatestRun.supersedes?("1.0.0", nil)
      refute LatestRun.supersedes?("0.6.9", "0.6.10")
      # Text order would get this one wrong.
      refute LatestRun.supersedes?("1.9.0", "1.10.0")
    end

    # Hex's `latest_version` and the registry's version order, which
    # `Portal.Workers.UpdateCheck` compares against: a pre-release counts,
    # and sorts below its own release.
    test "pre-releases follow Hex's precedence" do
      assert LatestRun.supersedes?("1.1.0-rc.1", "1.0.0")
      assert LatestRun.supersedes?("1.1.0", "1.1.0-rc.1")
      refute LatestRun.supersedes?("1.1.0-rc.2", "1.1.0")
      refute LatestRun.supersedes?("1.1.0-rc.9", "1.1.0-rc.10")
      refute LatestRun.supersedes?("1.0.5", "1.1.0-rc.1")
    end

    # Hex publishes none, so there is no order to keep: the newer run wins, as
    # every run did before.
    test "a version that does not parse supersedes and is superseded by any other" do
      assert LatestRun.supersedes?("unknown", "1.0.0")
      assert LatestRun.supersedes?("1.0.0", "unknown")
      assert LatestRun.supersedes?("other", "unknown")
    end
  end

  describe "newer?/2" do
    test "only a strictly higher version is newer" do
      assert LatestRun.newer?("0.6.10", "0.6.9")
      assert LatestRun.newer?("1.0.0", nil)
      refute LatestRun.newer?("0.6.10", "0.6.10")
      refute LatestRun.newer?("0.6.9", "0.6.10")
      refute LatestRun.newer?("1.1.0-rc.1", "1.1.0")
      assert LatestRun.newer?("1.1.0", "1.1.0-rc.1")
    end

    # There is no order to keep, and rebuilding is the safe direction
    # (`UpdateCheck.significant?/2`).
    test "a different version that does not parse is newer" do
      assert LatestRun.newer?("other", "unknown")
      assert LatestRun.newer?("not-a-version", "1.2.3")
      refute LatestRun.newer?("unknown", "unknown")
    end
  end

  defp ingest!(name, version, systems, opts \\ []) do
    package =
      %{"name" => name, "version" => version}
      |> Map.merge(Keyword.get(opts, :package, %{}))

    result =
      %{
        "package" => package,
        "finished_at" => Keyword.get(opts, :finished_at, DateTime.to_iso8601(DateTime.utc_now())),
        "scope" => Keyword.get(opts, :scope, "full"),
        "systems" => systems
      }

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: name,
        version: version,
        run_id: "r-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: System.tmp_dir!()
      })

    run
  end

  defp package!(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
  end

  defp systems_of(run) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.read!(domain: Catalog)
    |> Map.new(&{&1.system_pkg, &1})
  end

  describe "ingesting an older version" do
    # ssh_subsystem_fwup 0.6.9 and cc_precompiler 0.1.10, 2026-11-17: a forced
    # build of an old release became the package's latest version, on its page,
    # its badge and the JSON API.
    test "leaves the package's latest version, page, badge and API on the newer one" do
      newer =
        ingest!("oldpkg", "0.6.10", %{"nerves_system_rpi4" => %{"status" => "pass"}},
          finished_at: "2026-11-01T10:00:00Z",
          package: %{"description" => "new", "native_components" => %{"nif_language" => nil}}
        )

      older =
        ingest!("oldpkg", "0.6.9", %{"nerves_system_rpi4" => %{"status" => "fail"}},
          finished_at: "2026-11-17T10:00:00Z",
          package: %{"description" => "old", "native_components" => %{"nif_language" => "c"}}
        )

      package = package!("oldpkg")
      assert package.latest_version == "0.6.10"
      assert package.description == "new"
      assert package.native_components == %{"nif_language" => nil}
      assert package.last_run_at == ~U[2026-11-01 10:00:00Z]

      json = Catalog.latest_by_pkg_json("oldpkg").packages["oldpkg"]
      assert json.latest_version == "0.6.10"
      assert [%{status: "pass", run_id: run_id}] = Map.values(json.systems)
      assert run_id == newer.run_id

      assert [%{status: :pass}] = Catalog.latest_system_results("oldpkg")

      # The old release's run is kept, with its own results.
      assert Ash.get!(Run, older.id, domain: Catalog).version_tested == "0.6.9"
      assert systems_of(older)["nerves_system_rpi4"].status == :fail
      assert Build.latest_version_tested("oldpkg") == "0.6.10"
    end

    test "a newer release, or a rebuild of the latest one, still moves the package" do
      ingest!("movepkg", "1.0.0", %{"host" => %{"status" => "pass"}},
        finished_at: "2026-11-01T10:00:00Z"
      )

      ingest!("movepkg", "1.0.0", %{"host" => %{"status" => "fail"}},
        finished_at: "2026-11-02T10:00:00Z",
        package: %{"description" => "rebuilt"}
      )

      package = package!("movepkg")
      assert package.latest_version == "1.0.0"
      assert package.description == "rebuilt"
      assert package.last_run_at == ~U[2026-11-02 10:00:00Z]
      assert [%{status: :fail}] = Catalog.latest_system_results("movepkg")

      ingest!("movepkg", "1.1.0-rc.1", %{"host" => %{"status" => "pass"}})
      assert package!("movepkg").latest_version == "1.1.0-rc.1"

      ingest!("movepkg", "1.0.5", %{"host" => %{"status" => "fail"}})
      assert package!("movepkg").latest_version == "1.1.0-rc.1"
      assert [%{status: :pass}] = Catalog.latest_system_results("movepkg")

      ingest!("movepkg", "1.1.0", %{"host" => %{"status" => "pass"}})
      assert package!("movepkg").latest_version == "1.1.0"
    end

    # `Ingestion.ingest_toolchain/2` creates a package it has not seen with the
    # toolchain build's version and no run. A firmware run of any version then
    # becomes the package's latest: a latest version needs a run to show.
    test "takes over a latest version that has no run" do
      Package
      |> Ash.Changeset.for_create(:create, %{name: "toolonly", latest_version: "2.0.0"})
      |> Ash.create!(domain: Catalog)

      ingest!("toolonly", "1.0.0", %{"host" => %{"status" => "pass"}})

      assert package!("toolonly").latest_version == "1.0.0"
      assert [%{status: :pass}] = Catalog.latest_system_results("toolonly")
    end
  end

  describe "every reader of the latest run" do
    setup do
      Portal.Catalog.Cache.flush()

      ingest!(
        "readerpkg",
        "2.0.0",
        %{"nerves_system_rpi4" => %{"status" => "pass"}},
        finished_at: "2026-11-01T10:00:00Z"
      )

      ingest!(
        "readerpkg",
        "1.0.0",
        %{"nerves_system_rpi4" => %{"status" => "fail", "failure_category" => "Build timeout"}},
        finished_at: "2026-11-17T10:00:00Z"
      )

      :ok
    end

    test "/packages shows the latest version's statuses" do
      {[card], 1} = Portal.Catalog.Browse.page("readerpkg", 0, 10)
      assert card.version == "v2.0.0"
      assert card.statuses == ["pass"]
    end

    test "the dashboard counts and /failing read the latest version's run" do
      assert %{pass: 1, fail: 0} = Catalog.package_status_counts()
      assert Portal.Catalog.TopFailing.list() == []
    end
  end

  describe "a partial run of an older version" do
    # Carries from the newest run of its own version, never from the
    # package's latest run of another one.
    test "carries the systems it left out from its own version's newest run" do
      old_full =
        ingest!(
          "partialold",
          "1.0.0",
          %{
            "host" => %{"status" => "pass"},
            "nerves_system_rpi4" => %{"status" => "pass"},
            "nerves_system_bbb" => %{"status" => "fail"}
          },
          finished_at: "2026-11-01T10:00:00Z"
        )

      ingest!(
        "partialold",
        "2.0.0",
        %{"host" => %{"status" => "pass"}, "nerves_system_rpi4" => %{"status" => "pass"}},
        finished_at: "2026-11-02T10:00:00Z"
      )

      targets =
        ingest!("partialold", "1.0.0", %{"nerves_system_bbb" => %{"status" => "pass"}},
          scope: "targets",
          finished_at: "2026-11-03T10:00:00Z"
        )

      systems = systems_of(targets)
      assert Enum.sort(Map.keys(systems)) == ~w(host nerves_system_bbb nerves_system_rpi4)
      assert systems["nerves_system_bbb"].carried_from_run_id == nil
      assert systems["nerves_system_bbb"].status == :pass
      assert systems["nerves_system_rpi4"].carried_from_run_id == old_full.id
      assert systems["host"].carried_from_run_id == old_full.id
      assert targets.overall_status == :pass

      # The latest run is still the newer release's.
      assert package!("partialold").latest_version == "2.0.0"
      assert Build.latest_version_tested("partialold") == "2.0.0"
    end
  end
end
