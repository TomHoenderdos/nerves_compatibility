defmodule Portal.Catalog.ModuleIndexTest do
  # Round 3, R2-1: the modules each popular package's latest release
  # defines, and the refusal of a recorded declared-absent probe of one.
  # Round 5: the index is usable only once a run indexed every candidate
  # (R3-1), rechecks the served rows after a complete run (R3-5a), takes the
  # module names of our own build manifests too (R3-5b) and matches apps as
  # well as packages (R3-9).
  use Portal.DataCase, async: false

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

  defp packages!(rows) do
    now = NaiveDateTime.utc_now()

    rows =
      for {name, version, recent} <- rows,
          do: %{
            name: name,
            hex_latest_version: version,
            hex_downloads_recent: recent,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all("catalog_packages", rows)
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # money and ex_money define Money; amqp (app amqp) defines AMQP; jason
  # defines Jason; money_tiny is below the threshold.
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

    opts = [
      tarball: fn n, v -> Map.fetch(tarballs, {n, v}) end,
      outer_checksum: fn n, v -> {:ok, sha(Map.fetch!(tarballs, {n, v}))} end
    ]

    %{opts: opts, tarballs: tarballs}
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
    assert %{indexed: 4, failed: 0, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.complete?()
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money"]

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

  # The reviewer's scratch case 1 (R3-1): an index holding only jason,
  # written by a run that did not finish, decides nothing.
  test "an index that holds only some candidates refuses every record", %{opts: opts} do
    only_jason =
      Keyword.put(opts, :tarball, fn
        "jason", v -> opts[:tarball].("jason", v)
        _n, _v -> {:error, :hex_registry_unavailable}
      end)

    assert %{indexed: 1, failed: 3, complete: false} = ModuleIndex.refresh(only_jason)
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
    assert %{indexed: 1, unchanged: 3, complete: true} = ModuleIndex.refresh(opts)
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

  test "a run that is still going, or was stopped, keeps the index incomplete", %{opts: opts} do
    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.complete?()

    # A new run started and never finished (a deploy killed it).
    {:ok, _generation} = ModuleIndex.start_run(5)
    refute ModuleIndex.complete?()
    assert ModuleIndex.refusal([money()], []) =~ "module index not complete"

    # The next run completes again.
    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.complete?()
  end

  test "a dry run counts what a run would fetch and writes nothing", %{opts: opts} do
    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 4, unchanged: 0, below_threshold: 1}

    refute ModuleIndex.complete?()
    assert %{runs: 0} = ModuleIndex.status()
    ModuleIndex.refresh(failing(opts, "amqp"))

    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 1, unchanged: 3, below_threshold: 1}
  end

  test "at most 4 downloads at a time, whatever is asked", %{opts: opts} do
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

    opts = [
      tarball: counted,
      outer_checksum: fn
        "many_" <> _, _v -> {:ok, sha(stub)}
        n, v -> opts[:outer_checksum].(n, v)
      end,
      concurrency: 50
    ]

    assert %{indexed: 14, failed: 0, complete: true} = ModuleIndex.refresh(opts)
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

    assert %{indexed: 3, failed: 1, complete: false} =
             ModuleIndex.refresh(Keyword.put(opts, :tarball, crash))

    assert ModuleIndex.definers("Elixir.Money") == ["money"]
    assert %{to_fetch: 1, unchanged: 3} = ModuleIndex.refresh(Keyword.put(opts, :dry_run, true))
    assert %{indexed: 1, unchanged: 3, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money"]
  end

  test "a newer latest release replaces a package's modules", %{opts: opts} do
    ModuleIndex.refresh(opts)
    newer = tarball(%{"lib/money.ex" => "defmodule MoneyTwo do\nend\n"})
    Repo.query!("UPDATE catalog_packages SET hex_latest_version = '2.0.0' WHERE name = 'money'")

    opts = [
      tarball: fn
        "money", "2.0.0" -> {:ok, newer}
        n, v -> opts[:tarball].(n, v)
      end,
      outer_checksum: fn
        "money", "2.0.0" -> {:ok, sha(newer)}
        n, v -> opts[:outer_checksum].(n, v)
      end
    ]

    assert %{indexed: 1, unchanged: 3, complete: true} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money"]
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
         file_manifest, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, '1.4.4', '1.20/29', 1, 'with', 'default', 'pass', $2, now(), now())
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
end
