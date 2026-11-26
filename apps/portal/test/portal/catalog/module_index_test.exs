defmodule Portal.Catalog.ModuleIndexTest do
  # Round 3, R2-1: the modules each popular package's latest release
  # defines, and the refusal of a recorded declared-absent probe of one.
  # Round 5: the index is usable only once a run indexed every candidate
  # (R3-1), rechecks the served rows after a complete run (R3-5a), takes the
  # module names of our own build manifests too (R3-5b) and matches apps as
  # well as packages (R3-9).
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.ModuleIndex

  defp tarball(files, app \\ nil) do
    contents = for {path, body} <- files, do: {String.to_charlist(path), body}
    gz = Path.join(System.tmp_dir!(), "mi-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])
    bytes = File.read!(gz)
    File.rm!(gz)
    meta = if app, do: ~s({<<"app">>,<<"#{app}">>}.\n), else: ""
    tar = Path.join(System.tmp_dir!(), "mi-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [
        {~c"VERSION", "3"},
        {~c"metadata.config", meta},
        {~c"contents.tar.gz", bytes}
      ])

    out = File.read!(tar)
    File.rm!(tar)
    out
  end

  # As in production (round 6, R5-1): `hex_latest_version` is a nomination
  # column, NULL for almost every package. The latest release comes from the
  # Hex registry (`registry:`), never from the catalog.
  defp packages!(rows) do
    now = NaiveDateTime.utc_now()

    rows =
      for {name, _version, recent} <- rows,
          do: %{
            name: name,
            hex_latest_version: nil,
            hex_downloads_recent: recent,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all("catalog_packages", rows)
  end

  # `name => latest` (also the latest stable) or `name => {latest, stable}`.
  defp registry(versions) do
    releases =
      Map.new(versions, fn
        {n, {latest, stable}} -> {n, {latest, stable}}
        {n, v} -> {n, {v, v}}
      end)

    fn -> {:ok, releases} end
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # money and ex_money define Money; amqp (app amqp) defines AMQP; jason
  # defines Jason; money_tiny, below 1,000 recent downloads, defines Money
  # too: since S10 round 3 every package is indexed, and only a record's
  # refusal still counts popular definers alone.
  setup do
    tarballs = %{
      {"money", "1.14.0"} => tarball(%{"lib/money.ex" => "defmodule Money do\nend\n"}),
      {"ex_money", "5.24.2"} =>
        tarball(%{"lib/m.ex" => "defmodule Money do\nend\ndefmodule Cldr.Money do\nend\n"}),
      {"jason", "1.4.5"} => tarball(%{"lib/j.ex" => "defmodule Jason do\nend\n"}),
      {"amqp", "4.1.0"} => tarball(%{"lib/a.ex" => "defmodule AMQP do\nend\n"}, "amqp"),
      {"money_tiny", "0.1.0"} => tarball(%{"lib/m.ex" => "defmodule Money do\nend\n"})
    }

    packages!([
      {"money", "1.14.0", 398_436},
      {"ex_money", "5.24.2", 302_825},
      {"jason", "1.4.5", 11_209_930},
      {"amqp", "4.1.0", 120_000},
      {"money_tiny", "0.1.0", 12}
    ])

    latest = Map.new(tarballs, fn {{n, v}, _} -> {n, v} end)

    opts = [
      registry: registry(latest),
      tarball: fn n, v -> Map.fetch(tarballs, {n, v}) end,
      outer_checksum: fn n, v -> {:ok, sha(Map.fetch!(tarballs, {n, v}))} end
    ]

    %{opts: opts, tarballs: tarballs, latest: latest}
  end

  defp absent(module, declared, apps \\ nil),
    do: %{
      "kind" => "module_absent",
      "module" => module,
      "declared" => declared,
      "declared_apps" => apps || declared,
      "via" => "Code.ensure_loaded?/1"
    }

  defp money, do: absent("Elixir.Money", ["ex_money"])

  defp failing(opts, name),
    do:
      Keyword.put(opts, :tarball, fn
        ^name, _v -> {:error, :hex_registry_unavailable}
        n, v -> opts[:tarball].(n, v)
      end)

  test "a complete run indexes every candidate's latest release, and only then decides",
       %{opts: opts} do
    refute ModuleIndex.complete?()
    assert %{indexed: 5, failed: 0, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.complete?()
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money", "money_tiny"]

    # bitcrowd_ecto declares ex_money; money also defines Money.
    assert ModuleIndex.refusal([money()], ["ecto"]) ==
             "compile-time probe of a dependency outside the closure: Elixir.Money via " <>
               "Code.ensure_loaded?/1 (also defined by money)"

    # Every popular definer declared, or one in the lock: no refusal.
    assert ModuleIndex.refusal([absent("Elixir.Money", ["ex_money", "money"])], []) == nil
    assert ModuleIndex.refusal([money()], ["money"]) == nil
    assert ModuleIndex.refusal([absent("Elixir.Cldr.Money", ["ex_money"])], []) == nil
    assert ModuleIndex.refusal([], []) == nil
    assert ModuleIndex.refusal(nil, []) == nil
    assert ModuleIndex.refusal([%{"kind" => "truncated"}], []) =~ "declared-absent probes"
  end

  # Round 6, R5-1, the reviewer's production-shaped case: money's
  # `hex_latest_version` is NULL, as for 4,990 of the 5,008 candidates.
  # The index still fetches money's latest release from the registry, and
  # the bitcrowd_ecto `Money` record refuses.
  test "a candidate whose catalog latest version is NULL is still indexed", %{opts: opts} do
    assert Repo.query!(
             "SELECT count(*) FROM catalog_packages WHERE hex_latest_version IS NOT NULL"
           ).rows ==
             [[0]]

    assert %{to_fetch: 5} = ModuleIndex.refresh(Keyword.put(opts, :dry_run, true))
    assert %{indexed: 5, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money", "money_tiny"]
    assert ModuleIndex.refusal([money()], ["ecto"]) =~ "also defined by money"
  end

  test "a registry that cannot be read is a failed run, and the index stays incomplete",
       %{opts: opts} do
    down = Keyword.put(opts, :registry, fn -> {:error, :hex_registry_unavailable} end)
    assert %{complete: false, error: :hex_registry_unavailable} = ModuleIndex.refresh(down)
    refute ModuleIndex.complete?()
    assert ModuleIndex.refusal([money()], []) =~ "module index not complete"
  end

  # The reviewer's scratch case 1 (R3-1): an index holding only jason,
  # written by a run that did not finish, decides nothing.
  test "an index that holds only some candidates refuses every record", %{opts: opts} do
    only_jason =
      Keyword.put(opts, :tarball, fn
        "jason", v -> opts[:tarball].("jason", v)
        _n, _v -> {:error, :hex_registry_unavailable}
      end)

    assert %{indexed: 1, failed: 4, complete: false} = ModuleIndex.refresh(only_jason)
    assert ModuleIndex.definers("Elixir.Jason") == ["jason"]
    refute ModuleIndex.complete?()

    assert ModuleIndex.refusal([money()], ["ecto"]) =~
             "Elixir.Money via Code.ensure_loaded?/1 (module index not complete)"

    assert ModuleIndex.refusal([absent("Elixir.Cldr.Money", ["ex_money"])], []) =~
             "module index not complete"
  end

  # The reviewer's scratch case 2 (R3-1): money's fetch fails.
  test "a failed fetch keeps the index incomplete", %{opts: opts} do
    assert %{failed: 1, complete: false} = ModuleIndex.refresh(failing(opts, "money"))
    refute ModuleIndex.complete?()
    assert ModuleIndex.refusal([money()], []) =~ "module index not complete"

    # The next run fetches money and completes.
    assert %{indexed: 1, unchanged: 4, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.refusal([money()], []) =~ "also defined by money"
  end

  test "a tarball over the caps is a failure, not a package that defines nothing",
       %{opts: opts, tarballs: tarballs} do
    huge = :crypto.strong_rand_bytes(17 * 1024 * 1024)

    opts =
      opts
      |> Keyword.put(:tarball, fn
        "jason", _v -> {:ok, huge}
        n, v -> opts[:tarball].(n, v)
      end)
      |> Keyword.put(:outer_checksum, fn
        "jason", _v -> {:ok, sha(huge)}
        n, v -> {:ok, sha(Map.fetch!(tarballs, {n, v}))}
      end)

    assert %{failed: 1, complete: false} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Jason") == []
  end

  # Final round, R6-1, the reviewer's scratch case: money's registry latest
  # is a prerelease that drops `Money`, which the latest stable (what Mix
  # resolves by default) defines. Both are indexed, and both are needed.
  test "a prerelease that drops a module the latest stable defines lets no collision pass",
       %{opts: opts, latest: latest} do
    rc = tarball(%{"lib/money.ex" => "defmodule MoneyNext do\nend\n"})
    stable = Map.fetch!(latest, "money")

    tarball = fn
      "money", "2.0.0-rc.0" -> {:ok, rc}
      n, v -> opts[:tarball].(n, v)
    end

    checksum = fn
      "money", "2.0.0-rc.0" -> {:ok, sha(rc)}
      n, v -> opts[:outer_checksum].(n, v)
    end

    opts =
      Keyword.merge(opts,
        registry: registry(Map.put(latest, "money", {"2.0.0-rc.0", stable})),
        tarball: tarball,
        outer_checksum: checksum
      )

    assert %{to_fetch: 5, releases_to_fetch: 6} =
             ModuleIndex.refresh(Keyword.put(opts, :dry_run, true))

    assert %{indexed: 5, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money", "money_tiny"]
    assert ModuleIndex.definers("Elixir.MoneyNext") == ["money"]
    assert ModuleIndex.refusal([money()], ["ecto"]) =~ "also defined by money"

    # Completeness needs both: the stable release failing keeps it incomplete.
    stable_fails =
      Keyword.merge(opts,
        registry: registry(Map.put(latest, "money", {"2.0.0-rc.1", stable})),
        tarball: fn
          "money", "2.0.0-rc.1" -> {:ok, rc}
          "money", ^stable -> {:error, :hex_registry_unavailable}
          n, v -> tarball.(n, v)
        end,
        outer_checksum: fn
          "money", "2.0.0-rc.1" -> {:ok, sha(rc)}
          n, v -> checksum.(n, v)
        end
      )

    assert %{failed: 1, complete: false} = ModuleIndex.refresh(stable_fails)
    refute ModuleIndex.complete?()
  end

  # Final round: a run stays well under 1 GB on the web host. A tarball over
  # the big-parse size is parsed alone (aws parses at about 230 MB); smaller
  # ones go on at up to 4 at once.
  test "large tarballs are parsed one at a time", %{opts: opts, latest: latest} do
    counter = :counters.new(2, [])

    read = fn bytes, read_opts ->
      if byte_size(bytes) > 4_000 do
        :counters.add(counter, 1, 1)
        now = :counters.get(counter, 1)
        if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
        Process.sleep(80)
        :counters.sub(counter, 1, 1)
      end

      Compatibility.HexModules.read(bytes, read_opts)
    end

    big = for i <- 1..6, into: %{}, do: {"big_#{i}", "1.0.0"}
    for {n, _} <- big, do: packages!([{n, "1.0.0", 5_000}])
    filler = :crypto.strong_rand_bytes(6_000) |> Base.encode64()
    stub = tarball(%{"lib/b.ex" => "defmodule Big do\nend\n", "priv/blob.txt" => filler})

    opts =
      Keyword.merge(opts,
        registry: registry(Map.merge(latest, big)),
        tarball: fn
          "big_" <> _, _v -> {:ok, stub}
          n, v -> opts[:tarball].(n, v)
        end,
        outer_checksum: fn
          "big_" <> _, _v -> {:ok, sha(stub)}
          n, v -> opts[:outer_checksum].(n, v)
        end,
        read: read,
        big_parse_bytes: 4_000
      )

    assert %{indexed: 11, complete: true} = ModuleIndex.refresh(opts)
    assert :counters.get(counter, 2) == 1
  end

  test "the latest stable release of a registry version list" do
    assert ModuleIndex.latest_stable(["0.9.0", "1.0.0", "1.4.5", "1.5.0-alpha.2"]) == "1.4.5"
    assert ModuleIndex.latest_stable(["1.0.0-rc.0", "1.0.0-rc.1"]) == nil
    assert ModuleIndex.latest_stable(["1.10.0", "1.9.0"]) == "1.10.0"
    assert ModuleIndex.latest_stable(nil) == nil
  end

  # Round 6, R5-4: completeness is judged when the index is used, against
  # the current candidates and the releases the last run read.
  # S10 round 3: every catalog package is a candidate. One the catalog gains
  # after a complete run is seen from the next run on (new ones arrive every
  # day); that run indexes it and re-checks the served rows.
  test "a package new to the catalog after a complete run is indexed by the next run",
       %{opts: opts, latest: latest, tarballs: tarballs} do
    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.complete?()

    packages!([{"money_new", "0.1.0", 3}])
    assert ModuleIndex.complete?()
    refute "money_new" in ModuleIndex.definers("Elixir.Money")

    newer = tarball(%{"lib/m.ex" => "defmodule Money do\nend\n"})
    tarballs = Map.put(tarballs, {"money_new", "0.1.0"}, newer)

    opts = [
      registry: registry(Map.put(latest, "money_new", "0.1.0")),
      tarball: fn n, v -> Map.fetch(tarballs, {n, v}) end,
      outer_checksum: fn n, v -> {:ok, sha(Map.fetch!(tarballs, {n, v}))} end
    ]

    assert %{indexed: 1, complete: true} = ModuleIndex.refresh(opts)
    assert "money_new" in ModuleIndex.definers("Elixir.Money")
  end

  test "a new latest release makes the index incomplete until it is indexed",
       %{opts: opts, latest: latest} do
    assert %{complete: true} = ModuleIndex.refresh(opts)
    newer = tarball(%{"lib/money.ex" => "defmodule Money do\nend\n"})

    # A run that read money 2.0.0 from the registry but could not fetch it.
    failing = Keyword.merge(opts, registry: registry(Map.put(latest, "money", "2.0.0")))
    assert %{failed: 1, complete: false} = ModuleIndex.refresh(failing)
    refute ModuleIndex.complete?()

    fetched =
      Keyword.merge(opts,
        registry: registry(Map.put(latest, "money", "2.0.0")),
        tarball: fn
          "money", "2.0.0" -> {:ok, newer}
          n, v -> opts[:tarball].(n, v)
        end,
        outer_checksum: fn
          "money", "2.0.0" -> {:ok, sha(newer)}
          n, v -> opts[:outer_checksum].(n, v)
        end
      )

    assert %{indexed: 1, complete: true} = ModuleIndex.refresh(fetched)
    assert ModuleIndex.complete?()
  end

  # S10 round 4: the hourly, event-driven run reads only the candidates
  # whose release changed, and moves each candidate row with its index row,
  # so it never makes the index incomplete; a failed fetch leaves the
  # package where it was, for the next run.
  test "an incremental run reads only what changed and never makes the index incomplete",
       %{opts: opts, latest: latest} do
    assert %{incremental: true, skipped: :no_run} =
             ModuleIndex.refresh(Keyword.put(opts, :incremental, true))

    assert %{complete: true} = ModuleIndex.refresh(opts)
    newer = tarball(%{"lib/money.ex" => "defmodule MoneyTwo do\nend\n"})
    reads = :counters.new(1, [])

    moved = [
      registry: registry(Map.put(latest, "money", "2.0.0")),
      tarball: fn
        "money", "2.0.0" ->
          :counters.add(reads, 1, 1)
          {:ok, newer}

        n, v ->
          :counters.add(reads, 1, 1)
          opts[:tarball].(n, v)
      end,
      outer_checksum: fn
        "money", "2.0.0" -> {:ok, sha(newer)}
        n, v -> opts[:outer_checksum].(n, v)
      end,
      incremental: true
    ]

    failing = Keyword.put(moved, :tarball, fn _n, _v -> {:error, :hex_registry_unavailable} end)
    assert %{incremental: true, failed: 1, complete: true} = ModuleIndex.refresh(failing)
    assert ModuleIndex.complete?()
    refute "money" in ModuleIndex.definers("Elixir.MoneyTwo")

    assert %{incremental: true, to_fetch: 1} =
             ModuleIndex.refresh(Keyword.put(moved, :dry_run, true))

    assert %{incremental: true, indexed: 1, complete: true} = ModuleIndex.refresh(moved)
    assert :counters.get(reads, 1) == 1
    assert ModuleIndex.complete?()
    assert ModuleIndex.definers("Elixir.MoneyTwo") == ["money"]

    assert Repo.query!(
             "SELECT version FROM catalog_module_index_candidates WHERE package = 'money'"
           ).rows == [["2.0.0"]]
  end

  test "the hourly check queues one incremental run when a candidate changed, after a run",
       %{opts: opts, latest: latest} do
    entries = fn versions ->
      for {name, v} <- versions, do: %{name: name, latest_version: v, versions: [v]}
    end

    # No run yet: the index is built by the daily run, not by this one.
    assert ModuleIndex.queue_incremental(entries.(latest)) == 0
    refute_enqueued(worker: Portal.Workers.ModuleIndexRefresh)

    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.queue_incremental(entries.(latest)) == 0
    refute_enqueued(worker: Portal.Workers.ModuleIndexRefresh)

    moved = entries.(Map.put(latest, "money", "2.0.0"))
    assert ModuleIndex.queue_incremental(moved) == 1
    assert ModuleIndex.queue_incremental(moved) == 1
    assert [job] = all_enqueued(worker: Portal.Workers.ModuleIndexRefresh)
    assert job.args == %{"incremental" => true}
    assert ModuleIndex.queue_incremental(:not_a_list) == 0
  end

  # A run in progress does not make the index incomplete by itself: only
  # the candidates it has not confirmed at their latest release do.
  test "a run that started does not by itself make a complete index incomplete", %{opts: opts} do
    assert %{complete: true} = ModuleIndex.refresh(opts)
    {:ok, _generation} = ModuleIndex.start_run(4)
    assert ModuleIndex.complete?()
  end

  test "a dry run counts what a run would fetch and writes nothing", %{opts: opts} do
    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 5, releases_to_fetch: 5, unchanged: 0, not_in_registry: 0}

    refute ModuleIndex.complete?()
    assert %{runs: 0} = ModuleIndex.status()
    ModuleIndex.refresh(failing(opts, "amqp"))

    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 1, releases_to_fetch: 1, unchanged: 4, not_in_registry: 0}
  end

  test "at most 4 downloads at a time, whatever is asked", %{opts: opts, latest: latest} do
    counter = :counters.new(2, [])
    for i <- 1..10, do: packages!([{"many_#{i}", "1.0.0", 2_000}])
    stub = tarball(%{"lib/m.ex" => "defmodule Many do\nend\n"})

    lookup = fn
      "many_" <> _, _v -> {:ok, stub}
      n, v -> opts[:tarball].(n, v)
    end

    counted = fn n, v ->
      :counters.add(counter, 1, 1)
      now = :counters.get(counter, 1)
      if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
      Process.sleep(50)
      :counters.sub(counter, 1, 1)
      lookup.(n, v)
    end

    many = Map.new(1..10, &{"many_#{&1}", "1.0.0"})

    opts = [
      registry: registry(Map.merge(latest, many)),
      tarball: counted,
      outer_checksum: fn
        "many_" <> _, _v -> {:ok, sha(stub)}
        n, v -> opts[:outer_checksum].(n, v)
      end,
      concurrency: 50
    ]

    assert %{indexed: 15, failed: 0, complete: true} = ModuleIndex.refresh(opts)
    assert :counters.get(counter, 2) in 2..4
  end

  # Each package is stored in its own transaction as soon as it is read, so
  # a run killed part-way keeps what it stored, and the next run fetches
  # only the rest.
  test "a run that stops part-way resumes where it stopped", %{opts: opts} do
    crash = fn
      "ex_money", _v -> raise "killed"
      n, v -> opts[:tarball].(n, v)
    end

    assert %{indexed: 4, failed: 1, complete: false} =
             ModuleIndex.refresh(Keyword.put(opts, :tarball, crash))

    assert ModuleIndex.definers("Elixir.Money") == ["money", "money_tiny"]
    assert %{to_fetch: 1, unchanged: 4} = ModuleIndex.refresh(Keyword.put(opts, :dry_run, true))
    assert %{indexed: 1, unchanged: 4, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money", "money_tiny"]
  end

  test "a newer latest release replaces a package's modules", %{opts: opts, latest: latest} do
    ModuleIndex.refresh(opts)
    newer = tarball(%{"lib/money.ex" => "defmodule MoneyTwo do\nend\n"})

    opts = [
      registry: registry(Map.put(latest, "money", "2.0.0")),
      tarball: fn
        "money", "2.0.0" -> {:ok, newer}
        n, v -> opts[:tarball].(n, v)
      end,
      outer_checksum: fn
        "money", "2.0.0" -> {:ok, sha(newer)}
        n, v -> opts[:outer_checksum].(n, v)
      end
    ]

    assert %{indexed: 1, unchanged: 4, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money_tiny"]
    assert ModuleIndex.definers("Elixir.MoneyTwo") == ["money"]
  end

  # R3-5b: modules a macro defines, or a leex/yecc file, are in our own
  # build manifests of the package (and leex/yecc names in the source).
  test "the index takes the modules our passing builds of a package wrote", %{opts: opts} do
    {:ok, id} = Portal.Catalog.Ingestion.ensure_package_id("jason")

    Repo.query!(
      """
      INSERT INTO catalog_toolchain_builds
        (id, package_id, version, toolchain, builder_version, variant, config_variant, status,
         file_manifest, defined_modules, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, '1.4.4', '1.20/29', 1, 'with', 'default', 'pass', $2,
              ARRAY['Elixir.Jason.InMemory'], now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        %{
          "ebin" => [
            %{"path" => "ebin/Elixir.Jason.MacroMade.beam"},
            %{"path" => "ebin/jason.app"}
          ]
        }
      ]
    )

    leex =
      tarball(%{
        "lib/j.ex" => "defmodule Jason do\nend\n",
        "src/jason_lexer.xrl" => "Definitions.\n"
      })

    opts =
      opts
      |> Keyword.put(:tarball, fn
        "jason", _v -> {:ok, leex}
        n, v -> opts[:tarball].(n, v)
      end)
      |> Keyword.put(:outer_checksum, fn
        "jason", _v -> {:ok, sha(leex)}
        n, v -> opts[:outer_checksum].(n, v)
      end)

    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Jason.MacroMade") == ["jason"]
    # S10 round 3: and what their compile defined outside the ebin.
    assert ModuleIndex.definers("Elixir.Jason.InMemory") == ["jason"]
    assert ModuleIndex.definers("jason_lexer") == ["jason"]
    assert ModuleIndex.definers("jason") == []
  end

  # R3-9: hare declares app amqp from package amqp19; package amqp's app is
  # amqp too. Mix's app-name clash keeps a user with package amqp off the
  # build, so the probe is no collision.
  test "a definer whose app is declared or locked is no other definer", %{opts: opts} do
    assert %{complete: true} = ModuleIndex.refresh(opts)
    amqp = absent("Elixir.AMQP", ["amqp19"], ["amqp"])
    assert ModuleIndex.refusal([amqp], []) == nil

    assert ModuleIndex.refusal([%{amqp | "declared_apps" => ["amqp19"]}], []) =~
             "also defined by amqp"

    assert ModuleIndex.refusal([%{amqp | "declared_apps" => ["amqp19"]}], ["amqp"]) == nil
  end

  # S10: a module probe input carries every popular definer the index
  # shows, and its application, so client 0.10 can check its project for
  # them. Ingest refuses one while the index is not complete.
  describe "probe inputs" do
    defp probe(module, definers),
      do: %{
        "kind" => "probe",
        "of" => "module",
        "name" => module,
        "answer" => "absent",
        "definers" => definers
      }

    @app_probe %{"kind" => "probe", "of" => "app", "name" => "poison", "answer" => "absent"}

    # S10 round 5: nothing is added or refused at ingest any more; the
    # client decides each user's lock against the batch's release index.
    test "settle_inputs keeps the inputs, needs no index and refuses nothing", %{opts: opts} do
      env = %{"kind" => "env_all"}
      items = [probe("Elixir.Money", ["ex_money"]), @app_probe, env]

      assert ModuleIndex.settle_inputs(items) == {:ok, items}
      assert ModuleIndex.settle_inputs(nil) == {:ok, nil}
      assert ModuleIndex.settle_inputs(:malformed) == {:ok, :malformed}

      assert %{complete: true} = ModuleIndex.refresh(opts)
      assert ModuleIndex.settle_inputs(items) == {:ok, items}

      many = probe("Elixir.Money", for(i <- 1..64, do: "p#{1000 + i}"))
      assert ModuleIndex.settle_inputs([many]) == {:ok, [many]}

      # A declared item the release index cannot confirm loses `declared`.
      declared = Map.put(probe("Elixir.Money", ["ex_money"]), "declared", ["ex_money"])
      assert {:ok, [plain]} = ModuleIndex.settle_inputs([declared])
      refute Map.has_key?(plain, "declared")
    end

    test "a record a probe input carries is no refusal; one it does not carry is", %{opts: opts} do
      assert %{complete: true} = ModuleIndex.refresh(opts)

      assert ModuleIndex.refusal([money()], ["ecto"], [probe("Elixir.Money", ["ex_money"])]) ==
               nil

      assert ModuleIndex.refusal([], [], [probe("Elixir.Money", [])]) == nil

      # Another module's input carries nothing.
      assert ModuleIndex.refusal([money()], [], [probe("Elixir.Jason", ["money"])]) =~
               "also defined by money"
    end
  end
end
