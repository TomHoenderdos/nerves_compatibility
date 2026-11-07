defmodule Portal.Workers.ReleaseDownloadsRefreshTest do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ReleaseDownloads}
  alias Portal.Workers.{Build, ReleaseDownloadsRefresh, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}

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

  defp run!(name, version, finished_at \\ ~U[2026-10-20 10:00:00Z]) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version, "native_components" => @pure},
          "finished_at" => DateTime.to_iso8601(finished_at),
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

  defp downloads!(name, recent) do
    name
    |> package!()
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  defp built!(name, version) do
    Portal.Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package!(name).id,
      version: version,
      toolchain: "1.19/28",
      builder_version: 1,
      status: :pass,
      compile_env_rule: 1,
      run_id: "tc-row",
      compile_env: [],
      finished_at: DateTime.utc_now()
    })
    |> Ash.create!(domain: Catalog)
  end

  # A fetch that records what it was asked and answers from `answers`
  # (`{package, version} => result`), `{:ok, 7}` by default.
  defp recording_fetch(answers \\ %{}) do
    test = self()

    fn package, version ->
      send(test, {:fetched, package, version})
      Map.get(answers, {package, version}, {:ok, 7})
    end
  end

  defp recording_sleep do
    test = self()
    fn ms -> send(test, {:slept, ms}) end
  end

  defp refresh(opts) do
    ReleaseDownloadsRefresh.run(
      Keyword.merge([fetch: recording_fetch(), sleep: recording_sleep()], opts)
    )
  end

  defp fetched do
    receive do
      {:fetched, package, version} -> [{package, version} | fetched()]
    after
      0 -> []
    end
  end

  defp slept do
    receive do
      {:slept, ms} -> [ms | slept()]
    after
      0 -> []
    end
  end

  defp stored(package) do
    ReleaseDownloads
    |> Ash.Query.filter(package == ^package)
    |> Ash.read!(domain: Catalog)
    |> Map.new(&{&1.version, &1.downloads})
  end

  describe "run/1: what it asks hex.pm for" do
    # Only versions a sweep could still build: a version with a live build
    # has nothing left to order.
    test "only versions still in the toolchain backlog" do
      run!("jason", "1.4.4")
      run!("jason", "1.4.5")
      built!("jason", "1.4.5")
      downloads!("jason", 1_000)

      assert {:ok, _} = refresh([])
      assert fetched() == [{"jason", "1.4.4"}]
    end

    test "only the most downloaded packages, as many as asked" do
      for {name, recent} <- [{"a", 10}, {"b", 3_000}, {"c", 200}] do
        run!(name, "1.0.0")
        downloads!(name, recent)
      end

      assert {:ok, _} = refresh(top_packages: 2)
      assert Enum.sort(fetched()) == [{"b", "1.0.0"}, {"c", "1.0.0"}]
    end

    # Unknown demand has no rank to be in the top of.
    test "a package without a recent download count is not asked about" do
      run!("counted", "1.0.0")
      downloads!("counted", 5)
      run!("uncounted", "1.0.0")

      assert {:ok, _} = refresh([])
      assert fetched() == [{"counted", "1.0.0"}]
    end

    test "at most five versions per package by default, the newest" do
      for {version, day} <- Enum.with_index(~w(1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 1.6.0)) do
        run!("many", version, DateTime.add(~U[2026-10-01 00:00:00Z], day, :day))
      end

      downloads!("many", 1_000)

      assert {:ok, _} = refresh([])

      assert Enum.sort(fetched()) ==
               Enum.map(~w(1.2.0 1.3.0 1.4.0 1.5.0 1.6.0), &{"many", &1})
    end

    test "never more than top packages times versions per package requests" do
      for name <- ~w(a b c), version <- ~w(1.0.0 1.1.0 1.2.0) do
        run!(name, version)
      end

      for name <- ~w(a b c), do: downloads!(name, 100)

      assert {:ok, %{requested: 4}} = refresh(top_packages: 2, versions_per_package: 2)
      assert length(fetched()) == 4
    end
  end

  describe "run/1: pacing and failures" do
    setup do
      for version <- ~w(1.0.0 1.1.0 1.2.0) do
        run!("jason", version)
      end

      downloads!("jason", 1_000)
      :ok
    end

    # hex.pm rate-limits unauthenticated clients; 1.5 s apart keeps a full run
    # under it, as the package metadata refresh does.
    test "requests are spaced 1.5 s apart" do
      assert {:ok, %{requested: 3}} = refresh([])
      assert slept() == [1_500, 1_500]
    end

    test "each answer is stored with when it was fetched" do
      fetch =
        recording_fetch(%{
          {"jason", "1.0.0"} => {:ok, 10},
          {"jason", "1.1.0"} => {:ok, nil},
          {"jason", "1.2.0"} => {:ok, 3_000}
        })

      before = DateTime.utc_now()
      assert {:ok, %{stored: 3}} = refresh(fetch: fetch)
      assert stored("jason") == %{"1.0.0" => 10, "1.1.0" => nil, "1.2.0" => 3_000}

      for row <- Ash.read!(ReleaseDownloads, domain: Catalog) do
        assert DateTime.compare(row.fetched_at, before) != :lt
      end
    end

    test "a second run replaces the counts" do
      assert {:ok, _} = refresh([])
      assert {:ok, _} = refresh(fetch: recording_fetch(%{{"jason", "1.0.0"} => {:ok, 99}}))
      assert stored("jason") == %{"1.0.0" => 99, "1.1.0" => 7, "1.2.0" => 7}
    end

    # The rest of the run would only collect more 429s; next week's run
    # starts over.
    test "a rate limit stops the run, keeping what was already fetched" do
      fetch = recording_fetch(%{{"jason", "1.1.0"} => {:error, :rate_limited}})

      assert {:ok, %{requested: 2, stored: 1, stopped: :rate_limited}} = refresh(fetch: fetch)
      assert length(fetched()) == 2
      assert map_size(stored("jason")) == 1
    end

    test "any other failure skips that version and carries on" do
      fetch =
        recording_fetch(%{
          {"jason", "1.0.0"} => {:error, :unknown_release},
          {"jason", "1.1.0"} => {:error, :hex_api_unavailable}
        })

      assert {:ok, %{requested: 3, stored: 1, stopped: nil}} = refresh(fetch: fetch)
      assert map_size(stored("jason")) == 1
    end

    # Reordering the backlog is all this does: building stays the sweep's.
    test "enqueues no build" do
      assert {:ok, _} = refresh([])
      refute_enqueued(worker: Build)
      refute_enqueued(worker: ToolchainBuild)
    end
  end

  describe "the job" do
    # Downloads drift week to week; once a week is enough, and a second job
    # inside the week is the same work twice against hex.pm's rate limit.
    test "is unique for a week" do
      assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(ReleaseDownloadsRefresh.new(%{}))
      assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(ReleaseDownloadsRefresh.new(%{}))
      assert ReleaseDownloadsRefresh.__opts__()[:unique][:period] >= 7 * 86_400
    end

    # HTTP only, no build: a build host's queue would put it behind builds
    # that run for hours, and a build slot is what this exists to save.
    test "runs on the intake queue, never a build queue" do
      queue = ReleaseDownloadsRefresh.__opts__()[:queue]
      assert queue == :intake
      refute queue in [:builds, :toolchain, :remote]
    end

    # A failed run is not retried: the retry would land in the same rate
    # limit window that stopped it.
    test "is not retried" do
      assert ReleaseDownloadsRefresh.__opts__()[:max_attempts] == 1
    end
  end
end
