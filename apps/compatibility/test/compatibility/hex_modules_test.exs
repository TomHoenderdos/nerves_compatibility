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

  test "anything that is not a Hex tarball defines nothing" do
    assert HexModules.modules("not a tarball") == []
    assert HexModules.modules(nil) == []
  end
end
