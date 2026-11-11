defmodule Portal.Catalog.VersionBackfillTest do
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, VersionBackfill}

  import Portal.PrecompiledFixtures

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

  defp run!(name, version, opts \\ []) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{
            "name" => name,
            "version" => version,
            "native_components" => Keyword.get(opts, :native, @pure)
          },
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => %{"host" => %{"status" => Keyword.get(opts, :host, "pass")}}
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

  defp package!(name), do: Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!()

  defp downloads!(name, recent) do
    name
    |> package!()
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # A package that is only a download count: it takes a rank and nothing else.
  defp filler!(count, from_downloads) do
    rows = for i <- 1..count, do: package_row("filler_#{i}", from_downloads - i)
    {^count, _} = Repo.insert_all("catalog_packages", rows)
  end

  defp package_row(name, recent) do
    now = NaiveDateTime.utc_now()
    %{name: name, hex_downloads_recent: recent, inserted_at: now, updated_at: now}
  end

  defp release(version, opts \\ []),
    do: %{
      version: version,
      retired?: Keyword.get(opts, :retired, false),
      deps: [],
      outer_checksum: nil
    }

  # What `Portal.Test.FakeHexDeps` answers for each package, oldest first as
  # `Portal.HexDeps` returns them.
  defp releases!(map), do: Process.put({Portal.Test.FakeHexDeps, :releases}, map)

  defp minors(major, range), do: Enum.map(range, &release("#{major}.#{&1}.0"))

  defp row!(name, version, status, opts \\ []) do
    Portal.Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package!(name).id,
      version: version,
      toolchain: "1.19/28",
      builder_version: Keyword.get(opts, :builder_version, 1),
      status: status,
      compile_env_rule: 1,
      compile_env: [],
      deps_lock: %{},
      judge_revision: Keyword.get(opts, :judge_revision),
      run_id: "tc-row",
      finished_at: Keyword.get(opts, :finished_at, DateTime.utc_now())
    })
    |> Ash.create!(domain: Catalog)
  end

  defp backlog, do: Catalog.toolchain_backlog("1.19/28", 1, 10_000)
  defp versions(name), do: for(%{package: ^name, version: v} <- backlog(), do: v)

  describe "toolchain_backlog/3 with the version backfill" do
    test "a top package's last ten releases are wanted, newest first, and no older ones" do
      run!("top", "1.11.0")
      downloads!("top", 1_000_000)
      releases!(%{"top" => minors(1, 0..11)})

      assert versions("top") ==
               ~w(1.11.0 1.10.0 1.9.0 1.8.0 1.7.0 1.6.0 1.5.0 1.4.0 1.3.0 1.2.0)

      assert Enum.all?(backlog(), &(&1.variant == :with and not &1.refresh and not &1.reopen))
    end

    test "rank 1 gets ten releases, rank 300 four, rank 600 none" do
      filler!(600, 1_000_000)

      for {name, recent} <- [{"first", 2_000_000}, {"middle", 999_702}, {"tail", 999_400}] do
        run!(name, "1.11.0")
        downloads!(name, recent)
      end

      releases!(%{
        "first" => minors(1, 0..11),
        "middle" => minors(1, 0..11),
        "tail" => minors(1, 0..11)
      })

      assert {"middle", 300} in Catalog.version_backfill_packages(500)
      assert length(versions("first")) == 10
      assert versions("middle") == ~w(1.11.0 1.10.0 1.9.0 1.8.0)
      # Only its own run's version, which needs no backfill.
      assert versions("tail") == ["1.11.0"]
    end

    test "retired releases and pre-releases are skipped and do not count" do
      run!("pkg", "2.0.0")
      downloads!("pkg", 1_000)

      releases!(%{
        "pkg" =>
          [release("1.0.0"), release("1.1.0", retired: true)] ++
            Enum.map(~w(1.2.0 1.3.0 1.4.0 1.5.0 1.6.0 1.7.0 1.8.0 1.9.0 1.10.0), &release/1) ++
            [release("2.0.0"), release("2.1.0-rc.1")]
      })

      assert versions("pkg") ==
               ~w(2.0.0 1.10.0 1.9.0 1.8.0 1.7.0 1.6.0 1.5.0 1.4.0 1.3.0 1.2.0)
    end

    test "a package not known to be pure gets no backfill" do
      run!("failed", "2.0.0", host: "fail")
      run!("native", "2.0.0", native: %{"nif_language" => "c", "port_languages" => []})
      run!("port", "2.0.0", native: %{"nif_language" => nil, "port_languages" => ["c"]})
      for name <- ~w(failed native port), do: downloads!(name, 1_000)
      # Known to hex.pm and downloaded, but never run here.
      {1, _} = Repo.insert_all("catalog_packages", [package_row("norun", 1_000)])
      releases!(Map.new(~w(failed native port norun), &{&1, minors(1, 0..3)}))

      assert backlog() == []
    end

    test "a version with a live build is left out" do
      run!("pkg", "1.3.0")
      downloads!("pkg", 1_000)
      releases!(%{"pkg" => minors(1, 0..3)})
      row!("pkg", "1.3.0", :pass)
      row!("pkg", "1.1.0", :skipped)

      assert versions("pkg") == ~w(1.2.0 1.0.0)
    end

    test "an error on a backfilled version is final until a new judge revision" do
      run!("pkg", "1.2.0")
      downloads!("pkg", 1_000)
      releases!(%{"pkg" => minors(1, 0..2)})
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      row!("pkg", "1.2.0", :error, finished_at: two_days_ago)
      row!("pkg", "1.1.0", :error, finished_at: two_days_ago)
      row!("pkg", "1.0.0", :pass)

      # The version with a run of its own is retried a day later; the
      # backfilled one is not.
      assert Enum.map(backlog(), &{&1.version, &1.backfill}) == [{"1.2.0", false}]

      # A judge revision first written after the error reopens it once.
      row!("pkg", "1.0.0", :pass, builder_version: 2, judge_revision: 1)
      assert versions("pkg") == ["1.2.0"]

      run!("other", "1.0.0")
      row!("other", "1.0.0", :pass, judge_revision: 1)
      assert versions("pkg") == ~w(1.2.0 1.1.0)
    end

    test "an old release of a popular package ranks before a new one of an obscure one" do
      run!("popular", "2.0.0")
      downloads!("popular", 1_000_000)
      run!("obscure", "9.0.0")
      downloads!("obscure", 40)
      releases!(%{"popular" => [release("1.0.0"), release("2.0.0")]})
      row!("popular", "2.0.0", :pass)

      assert Enum.map(backlog(), &{&1.package, &1.version}) == [
               {"popular", "1.0.0"},
               {"obscure", "9.0.0"}
             ]
    end

    test "the hex.pm release list is read only for packages in scope" do
      filler!(10, 1_000_000)
      run!("pkg", "1.0.0")
      downloads!("pkg", 2_000_000)
      parent = self()

      hex_releases = fn name ->
        send(parent, {:asked, name})
        {:ok, [release("0.9.0"), release("1.0.0")]}
      end

      tiers = %{top_packages: 1, top_versions: 2, packages: 1, versions: 1}

      assert VersionBackfill.wanted(hex_releases: hex_releases, tiers: tiers) == [
               {"pkg", "1.0.0"},
               {"pkg", "0.9.0"}
             ]

      assert_received {:asked, "pkg"}
      refute_received {:asked, _}
    end

    test "asks no more after three unavailable answers, and skips a missing package" do
      for {name, recent} <- [{"a", 6}, {"b", 5}, {"c", 4}, {"d", 3}, {"e", 2}, {"f", 1}] do
        run!(name, "1.0.0")
        downloads!(name, recent)
      end

      parent = self()

      answers = %{
        "a" => {:error, :not_found},
        "b" => {:ok, [release("0.1.0")]},
        "c" => {:error, :hex_registry_unavailable},
        "d" => {:error, :hex_registry_unavailable},
        "e" => {:error, :hex_registry_undecodable},
        "f" => {:ok, [release("0.1.0")]}
      }

      hex_releases = fn name ->
        send(parent, {:asked, name})
        Map.fetch!(answers, name)
      end

      # Asked several at a time, so "f" may be asked, but its answer is not used.
      assert VersionBackfill.wanted(hex_releases: hex_releases) == [{"b", "0.1.0"}]
      for name <- ~w(a b c d e), do: assert_received({:asked, ^name})
    end

    test "asks at most eight packages at once" do
      for i <- 1..24 do
        run!("pkg#{i}", "1.0.0")
        downloads!("pkg#{i}", 100 - i)
      end

      table = :ets.new(:in_flight, [:public])
      :ets.insert(table, [{:now, 0}, {:max, 0}])

      hex_releases = fn _name ->
        now = :ets.update_counter(table, :now, 1)
        [{:max, max}] = :ets.lookup(table, :max)
        if now > max, do: :ets.insert(table, {:max, now})
        Process.sleep(20)
        :ets.update_counter(table, :now, -1)
        {:ok, [release("0.1.0")]}
      end

      assert length(VersionBackfill.wanted(hex_releases: hex_releases)) == 24
      assert [{:max, max}] = :ets.lookup(table, :max)
      assert max in 2..8
    end

    @tag :capture_log
    test "past its time budget it starts no request and keeps what it has" do
      run!("pkg", "1.0.0")
      downloads!("pkg", 1)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert VersionBackfill.wanted(hex_releases: fn _ -> flunk("asked") end, budget_ms: 0) ==
                   []
        end)

      assert log =~ "time budget"
    end

    test "a tier of zero versions asks nothing for it" do
      run!("pkg", "1.0.0")
      downloads!("pkg", 1)
      tiers = %{top_packages: 100, top_versions: 0, packages: 500, versions: 0}

      assert VersionBackfill.wanted(hex_releases: fn _ -> flunk("asked") end, tiers: tiers) ==
               []
    end
  end

  describe "the format-2 manifest" do
    test "lists a toolchain build of a version the catalog has no run of" do
      run!("old_pkg", "2.0.0")
      ingest_toolchain_build("old_pkg", "2.0.0")
      ingest_toolchain_build("old_pkg", "1.0.0")

      assert %{"versions" => %{"1.0.0" => %{"builds" => [_]}, "2.0.0" => %{"builds" => [_]}}} =
               Catalog.precompiled_manifest_v2("old_pkg")

      assert %{v2: %{"versions" => %{"1.0.0" => _}}} = Catalog.precompiled_manifests("old_pkg")
    end
  end
end
