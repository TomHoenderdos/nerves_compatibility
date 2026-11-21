defmodule Portal.Catalog.ModuleIndexTest do
  # Round 3, R2-1: the modules each popular package's latest release
  # defines, and the refusal of a recorded declared-absent probe of one.
  use Portal.DataCase, async: true

  alias Portal.Catalog.ModuleIndex

  defp tarball(files) do
    contents = for {path, body} <- files, do: {String.to_charlist(path), body}
    gz = Path.join(System.tmp_dir!(), "mi-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])
    bytes = File.read!(gz)
    File.rm!(gz)
    tar = Path.join(System.tmp_dir!(), "mi-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"VERSION", "3"}, {~c"contents.tar.gz", bytes}])

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

  setup do
    money = tarball(%{"lib/money.ex" => "defmodule Money do\nend\n"})
    ex_money = tarball(%{"lib/m.ex" => "defmodule Money do\nend\ndefmodule Cldr.Money do\nend\n"})
    tiny = tarball(%{"lib/m.ex" => "defmodule Money do\nend\n"})
    bad = tarball(%{"lib/bad.ex" => "defmodule Tampered do\nend\n"})

    packages!([
      {"money", "1.14.0", 398_436},
      {"ex_money", "5.24.2", 302_825},
      {"money_tiny", "0.1.0", 12},
      {"tampered", "1.0.0", 5_000}
    ])

    tarballs = %{
      {"money", "1.14.0"} => money,
      {"ex_money", "5.24.2"} => ex_money,
      {"money_tiny", "0.1.0"} => tiny,
      {"tampered", "1.0.0"} => bad
    }

    opts = [
      tarball: fn n, v -> {:ok, Map.fetch!(tarballs, {n, v})} end,
      outer_checksum: fn
        "tampered", _v -> {:ok, String.duplicate("0", 64)}
        n, v -> {:ok, sha(Map.fetch!(tarballs, {n, v}))}
      end
    ]

    %{opts: opts}
  end

  defp absent(module, declared),
    do: %{
      "kind" => "module_absent",
      "module" => module,
      "declared" => declared,
      "via" => "Code.ensure_loaded?/1"
    }

  test "indexes the latest release of each package with 1,000 or more recent downloads",
       %{opts: opts} do
    refute ModuleIndex.built?()
    assert %{indexed: 2, failed: 1} = ModuleIndex.refresh(opts)
    assert ModuleIndex.built?()
    # Below the threshold: not indexed. A tarball that does not hash to the
    # registry's outer checksum: not indexed.
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money", "money"]
    assert ModuleIndex.definers("Elixir.Tampered") == []
  end

  test "a declared-absent probe refuses when another popular package defines the module",
       %{opts: opts} do
    ModuleIndex.refresh(opts)

    # bitcrowd_ecto declares ex_money; money also defines Money.
    assert ModuleIndex.refusal([absent("Elixir.Money", ["ex_money"])], ["ecto"]) ==
             "compile-time probe of a dependency outside the closure: Elixir.Money via " <>
               "Code.ensure_loaded?/1 (also defined by money)"

    # Every popular definer declared, or one in the lock: no refusal.
    assert ModuleIndex.refusal([absent("Elixir.Money", ["ex_money", "money"])], []) == nil
    assert ModuleIndex.refusal([absent("Elixir.Money", ["ex_money"])], ["money"]) == nil
    # Only the declared package defines it.
    assert ModuleIndex.refusal([absent("Elixir.Cldr.Money", ["ex_money"])], []) == nil
    assert ModuleIndex.refusal([], []) == nil
    assert ModuleIndex.refusal(nil, []) == nil

    # A list the worker cut short refuses.
    assert ModuleIndex.refusal([%{"kind" => "truncated"}], []) =~ "declared-absent probes"
  end

  test "before the index is built, every declared-absent probe refuses" do
    assert ModuleIndex.refusal([absent("Elixir.Cldr.Money", ["ex_money"])], []) =~
             "Elixir.Cldr.Money via Code.ensure_loaded?/1 (module index not built)"

    assert ModuleIndex.refusal([], []) == nil
  end

  # Round 4: the first run, started by hand on the web host.
  test "a dry run counts what a run would fetch and writes nothing", %{opts: opts} do
    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 3, unchanged: 0, below_threshold: 1}

    refute ModuleIndex.built?()
    ModuleIndex.refresh(opts)
    # tampered failed: it is fetched again next time.
    assert ModuleIndex.refresh(Keyword.put(opts, :dry_run, true)) ==
             %{to_fetch: 1, unchanged: 2, below_threshold: 1}
  end

  test "at most 4 downloads at a time, whatever is asked", %{opts: opts} do
    me = self()
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
      send(me, {:fetched, n})
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

    assert %{indexed: 12, failed: 1} = ModuleIndex.refresh(opts)
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

    assert %{indexed: 1, failed: 2} = ModuleIndex.refresh(Keyword.put(opts, :tarball, crash))
    assert ModuleIndex.definers("Elixir.Money") == ["money"]
    assert %{to_fetch: 2, unchanged: 1} = ModuleIndex.refresh(Keyword.put(opts, :dry_run, true))
    assert %{indexed: 1, unchanged: 1} = ModuleIndex.refresh(opts)
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

    assert %{indexed: 1, unchanged: 1} = ModuleIndex.refresh(opts)
    assert ModuleIndex.definers("Elixir.Money") == ["ex_money"]
    assert ModuleIndex.definers("Elixir.MoneyTwo") == ["money"]
  end
end
