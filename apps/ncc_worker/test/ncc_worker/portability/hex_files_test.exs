defmodule NccWorker.Portability.HexFilesTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.HexFiles

  defp tarball(members), do: tarball_bytes(members)

  def tarball_bytes(members) do
    path = Path.join(System.tmp_dir!(), "ncc-hexfiles-#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), for({n, b} <- members, do: {~c"#{n}", b}))
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  @meta ~s({<<"app">>,<<"pkg">>}.\n{<<"build_tools">>,[<<"mix">>]}.\n) <>
          ~s({<<"files">>,[<<"lib">>,<<"lib/a.ex">>,<<"README.md">>]}.\n) <>
          ~s({<<"requirements">>,[[{<<"app">>,<<"x">>},{<<"optional">>,false}]]}.\n)

  test "the files list of a tarball's metadata.config" do
    bytes = tarball([{"VERSION", "3"}, {"metadata.config", @meta}, {"contents.tar.gz", ""}])
    assert HexFiles.from_tarball(bytes) == [["lib"], ["lib", "a.ex"], ["README.md"]]
  end

  test "no metadata.config, no files key or no tarball is unknown" do
    assert HexFiles.from_tarball(tarball([{"VERSION", "3"}])) == nil

    assert HexFiles.from_tarball(tarball([{"metadata.config", ~s({<<"app">>,<<"p">>}.\n)}])) ==
             nil

    assert HexFiles.from_tarball("not a tar") == nil
    assert HexFiles.from_tarball(nil) == nil
  end

  test "an oversized metadata.config is unknown" do
    big = @meta <> "%" <> String.duplicate("x", 1_100_000) <> "\n"
    assert HexFiles.from_tarball(tarball([{"metadata.config", big}])) == nil
  end

  test "parses the terms Hex writes without creating atoms" do
    name = "ncc_never_seen_atom_#{System.unique_integer([:positive])}"

    meta =
      ~s(%% comment\n{<<"files">>,[<<"lib/caf\\x{E9}.ex"/utf8>>,<<"n\\303\\251">>,<<"priv/a b">>]}.\n) <>
        ~s({<<"x">>,#{name}}.\n{<<"y">>,'#{name}_q'}.\n{<<"m">>,\#{<<"k">> => [1,-2,3.5e1,"str"]}}.\n)

    assert {:ok, terms} = HexFiles.parse(meta)
    assert {"files", ["lib/café.ex", <<"n", 0o303, 0o251>>, "priv/a b"]} = hd(terms)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(name <> "_q") end
  end

  test "malformed input is an error, never a raise" do
    for bad <- [
          ~s({<<"files">>,[<<"lib">>]}),
          ~s({<<"files">>,[<<"lib>>]}.),
          ~s({<<"files">>,[<<"l\\x{110000}">>]}.),
          ~S({<<"files">>,[<<"l\^1">>]}.),
          "{<<\"files\">>,[<<\"l\\",
          ~s({<<"files">>,[<<"lib">>}.),
          ~s({<<"files">>,[<<300>>]}.),
          String.duplicate("[", 200) <> String.duplicate("]", 200) <> "."
        ] do
      assert HexFiles.parse(bad) == :error, bad
    end
  end

  test "escapes follow erl_scan: an unknown one is the character itself, \\^c a control" do
    # hackney 4.9.1's rebar.config: {platform_define, "^20\.3", ...}
    assert {:ok, [{{:atom, "x"}, [94, 50, 48, 46, 51], [1, 113, 127, 27]}]} =
             HexFiles.parse(~S({x, "^20\.3", "\^a\q\^?\^["}.) <> "\n")
  end

  test "entries are path segments; absolute, empty and .. entries are dropped" do
    meta =
      ~s({<<"files">>,[<<"..">>,<<"/">>,<<"">>,<<"../../mix.exs">>,<<".">>,{x},<<"./lib/">>,<<"a/../b">>]}.\n)

    assert HexFiles.from_tarball(tarball([{"metadata.config", meta}])) == [["lib"]]
  end
end
