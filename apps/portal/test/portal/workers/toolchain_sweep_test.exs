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
        %{run_id: run_id, image_digest: "sha256:x", files_dir: System.tmp_dir!()}
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
               %{package: "no_native", version: "1.0.0"},
               %{package: "old_error", version: "1.0.0"},
               %{package: "old_fail", version: "1.0.0"},
               %{package: "wanted", version: "1.0.0"}
             ]
    end

    test "a row for another toolchain or builder version is not live here" do
      run!("other", "1.0.0")
      toolchain_row!("other", "1.0.0", :pass, toolchain: "1.20/29")
      toolchain_row!("other", "1.0.0", :pass, builder_version: 2)

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               %{package: "other", version: "1.0.0"}
             ]

      assert Catalog.toolchain_backlog("1.20/29", 1, 100) == []
      assert Catalog.toolchain_backlog("1.19/28", 2, 100) == []
    end

    test "the newest three versions of each package come first" do
      for {version, day} <- [{"1.0.0", 1}, {"1.1.0", 2}, {"1.2.0", 3}, {"1.3.0", 4}, {"1.4.0", 5}] do
        run!("many", version,
          finished_at: DateTime.new!(~D[2026-10-01], ~T[00:00:00]) |> DateTime.add(day, :day)
        )
      end

      run!("single", "0.1.0", finished_at: ~U[2026-09-01 00:00:00Z])

      backlog = Catalog.toolchain_backlog("1.19/28", 1, 100)

      assert Enum.take(backlog, 4) |> Enum.sort_by(&{&1.package, &1.version}) == [
               %{package: "many", version: "1.2.0"},
               %{package: "many", version: "1.3.0"},
               %{package: "many", version: "1.4.0"},
               %{package: "single", version: "0.1.0"}
             ]

      assert Enum.drop(backlog, 4) == [
               %{package: "many", version: "1.1.0"},
               %{package: "many", version: "1.0.0"}
             ]

      assert length(Catalog.toolchain_backlog("1.19/28", 1, 2)) == 2
    end

    test "a version with several runs is listed once" do
      run!("twice", "1.0.0", finished_at: ~U[2026-10-01 00:00:00Z])
      run!("twice", "1.0.0", finished_at: ~U[2026-10-02 00:00:00Z])

      assert Catalog.toolchain_backlog("1.19/28", 1, 100) == [
               %{package: "twice", version: "1.0.0"}
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
               "builder_version" => 1
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
