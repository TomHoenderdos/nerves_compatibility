defmodule Compatibility.HexModulesTest do
  use ExUnit.Case, async: true

  alias Compatibility.HexModules

  defp tarball(files) do
    contents = for {path, body} <- files, do: {String.to_charlist(path), body}
    gz = Path.join(System.tmp_dir!(), "hm-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])
    bytes = File.read!(gz)
    File.rm!(gz)
    tar = Path.join(System.tmp_dir!(), "hm-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"VERSION", "3"}, {~c"contents.tar.gz", bytes}])

    out = File.read!(tar)
    File.rm!(tar)
    out
  end

  test "the modules a Hex tarball's sources define, without creating atoms" do
    bytes =
      tarball(%{
        "lib/a.ex" => """
        defmodule HmA do
          defmodule Inner do
          end

          defimpl String.Chars do
            def to_string(_), do: "x"
          end
        end

        defprotocol HmA.Proto do
          def f(x)
        end

        defimpl HmA.Proto, for: [Integer, Atom] do
          def f(x), do: x
        end

        defmodule NeverAnAtomBeforeThisTestXyz do
        end
        """,
        "src/hm_erl.erl" => "-module(hm_erl).\n-export([f/0]).\nf() -> ok.\n",
        "README.md" => "defmodule NotSource do end"
      })

    modules = HexModules.modules(bytes)

    for m <- ~w(Elixir.HmA Elixir.HmA.Inner Elixir.String.Chars.HmA Elixir.HmA.Proto
                Elixir.HmA.Proto.Integer Elixir.HmA.Proto.Atom hm_erl
                Elixir.NeverAnAtomBeforeThisTestXyz),
        do: assert(m in modules, m)

    refute "Elixir.NotSource" in modules
    assert_raise ArgumentError, fn -> String.to_existing_atom("NeverAnAtomBeforeThisTestXyz") end
  end

  # S10 round 3: which of them a `defprotocol` names and which a `defimpl`
  # makes, for the declared-optional-dependency rule's review gate.
  test "read names the protocols and the implementations among the modules" do
    bytes =
      tarball(%{
        "lib/p.ex" => """
        defprotocol HmP.Encoder do
          def encode(x)
        end

        defimpl HmP.Encoder, for: Integer do
          def encode(x), do: x
        end

        defmodule HmP do
          defimpl String.Chars do
            def to_string(_), do: "p"
          end
        end
        """
      })

    assert {:ok, read} = HexModules.read(bytes)
    assert read.protocols == ["Elixir.HmP.Encoder"]
    assert Enum.sort(read.impls) == ["Elixir.HmP.Encoder.Integer", "Elixir.String.Chars.HmP"]

    assert Enum.sort(read.modules) ==
             ~w(Elixir.HmP Elixir.HmP.Encoder Elixir.HmP.Encoder.Integer Elixir.String.Chars.HmP)
  end

  # Round 6: what a real index run of the 5,008 popular packages hit.
  test "hidden files, many non-source files and large Erlang sources are read" do
    many = for i <- 1..6_000, into: %{}, do: {"priv/icons/i#{i}.svg", "<svg/>"}

    bytes =
      tarball(
        Map.merge(many, %{
          "lib/a.ex" => "defmodule HmMany do\nend\n",
          # macOS AppleDouble junk, which Mix's lib/**/*.ex never matches.
          "lib/._a.ex" => <<0, 5, 22, 7, 0, 2, 0, 0>>,
          "src/hm_big.erl" => "-module(hm_big).\n" <> String.duplicate("%% pad\n", 5_000_000)
        })
      )

    assert {:ok, %{modules: modules}} = HexModules.read(bytes, max_tarball: 64 * 1024 * 1024)
    assert "Elixir.HmMany" in modules
    assert "hm_big" in modules
  end

  # S10 review S5: an Erlang module is named by its file, which
  # `compile:file` checks the `-module` against. `-module (x).`, `-module(?M).`
  # and a `-module` in an included `.hrl` all compile, and a regex on the
  # form misses them.
  test "an Erlang source's module is its file's base name" do
    bytes =
      tarball(%{
        "src/hm_spaced.erl" => "-module (hm_spaced).\n-export([f/0]).\nf() -> ok.\n",
        "src/hm_macro.erl" => "-define(M, hm_macro).\n-module(?M).\n",
        "src/hm_hrl.erl" => "-include(\"hm_hrl.hrl\").\n",
        "include/hm_hrl.hrl" => "-module(hm_hrl).\n"
      })

    modules = HexModules.modules(bytes)
    for m <- ~w(hm_spaced hm_macro hm_hrl), do: assert(m in modules, m)
  end

  test "anything that is not a Hex tarball defines nothing" do
    assert HexModules.modules("not a tarball") == []
    assert HexModules.modules(nil) == []
  end
end
