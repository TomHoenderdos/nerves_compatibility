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
