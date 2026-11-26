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

  # S10 review U9: only what Mix or rebar3 compiles (closure_table's
  # bundled `examples/ct_ecto/deps/postgrex` defines no module of it).
  test "only the dirs Mix compiles count" do
    files = %{
      "lib/a.ex" => "defmodule HmLibA do\nend\n",
      "examples/ct/deps/postgrex/lib/p.ex" => "defmodule HmBundledPostgrex do\nend\n",
      "src/hm_src.erl" => "-module(hm_src).\n",
      "examples/ct/deps/x/src/hm_bundled.erl" => "-module(hm_bundled).\n"
    }

    modules = files |> tarball() |> HexModules.modules()
    assert Enum.sort(modules) == ["Elixir.HmLibA", "hm_src"]

    # A dir `mix.exs` names is compiled; a computed one reads everything.
    named =
      Map.put(
        files,
        "mix.exs",
        ~s|def project, do: [elixirc_paths: ["lib", "examples/ct/deps/postgrex/lib"]]|
      )

    assert "Elixir.HmBundledPostgrex" in HexModules.modules(tarball(named))

    computed =
      Map.put(files, "mix.exs", ~s|def project, do: [elixirc_paths: Path.wildcard("x/*")]|)

    assert Enum.sort(HexModules.modules(tarball(computed))) ==
             ["Elixir.HmBundledPostgrex", "Elixir.HmLibA", "hm_bundled", "hm_src"]
  end

  # S10 re-review R5-2: a build script or hook can compile what neither
  # `mix.exs` nor `rebar.config` names. gpb 4.21.7 has a
  # `rebar.config.script` and a Makefile, and its post-compile hook
  # compiles `descr_src/gpb_compile_descr.erl` and `gpb_parse_descr.erl`
  # into its ebin. (The real release: `mix hex.package fetch gpb 4.21.7`.)
  test "gpb 4.21.7: a build script reads every source" do
    bytes = File.read!(Path.expand("../fixtures/hex/gpb-4.21.7.tar", __DIR__))

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
             "9b3c3adfea1a631fd1da6b2b08ec8f59b412982393950e0fd1b306def79a676a"

    assert {:ok, %{app: "gpb", modules: modules}} = HexModules.read(bytes)
    assert "gpb_compile_descr" in modules
    assert "gpb_parse_descr" in modules
    assert "gpb_compile" in modules
  end

  test "a build script, a rebar3 hook, a compile alias or a non-literal path reads every source" do
    base = %{
      "lib/a.ex" => "defmodule HmR52A do\nend\n",
      "extra/b.ex" => "defmodule HmR52Extra do\nend\n",
      "descr_src/hm_descr.erl" => "-module(hm_descr).\n"
    }

    read = fn files -> files |> tarball() |> HexModules.modules() |> Enum.sort() end
    assert read.(base) == ["Elixir.HmR52A"]

    all = ["Elixir.HmR52A", "Elixir.HmR52Extra", "hm_descr"]

    for {file, body} <- [
          {"rebar.config.script", "CONFIG."},
          {"Makefile", "all:\n"},
          {"erlang.mk", ""},
          {"rebar.config", "{post_hooks, [{compile, \"make descr\"}]}."},
          {"rebar.config", "{provider_hooks, [{post, [{compile, {pc, compile}}]}]}."},
          {"mix.exs", "def project, do: [compilers: [:elixir_make] ++ Mix.compilers()]"},
          {"mix.exs", ~s|defp aliases, do: [compile: ["compile", &extra/1]]|},
          {"mix.exs", "defp elixirc_paths(_), do: ~w(lib extra)"},
          {"mix.exs", "def project, do: [elixirc_paths: @paths]"}
        ] do
      assert read.(Map.put(base, file, body)) == all, file
    end
  end

  # S10 re-review R5-2: a `.ex` in any dir read that does not parse makes
  # the release unreadable (a newer Elixir may compile it), not only in
  # `lib/`; an EEx template outside `lib/` (phoenix's `priv/templates`) is
  # compiled by nothing as it is and defines nothing.
  test "a source that does not parse is unreadable in any dir read, a template outside lib is not" do
    named = %{
      "mix.exs" => ~s|def project, do: [elixirc_paths: ["lib", "web"]]|,
      "lib/a.ex" => "defmodule HmR52B do\nend\n"
    }

    assert {:error, {:unparsed, "web/x.ex"}} =
             named |> Map.put("web/x.ex", "defmodule (") |> tarball() |> HexModules.read()

    template = "defmodule <%= @mod %>.Html do\nend\n"

    assert {:ok, %{modules: ["Elixir.HmR52B"]}} =
             named |> Map.put("web/t.ex", template) |> tarball() |> HexModules.read()

    assert {:error, {:unparsed, "lib/t.ex"}} =
             named |> Map.put("lib/t.ex", template) |> tarball() |> HexModules.read()

    # Every source read: a template defines nothing, anything else unparsed fails.
    all = Map.put(named, "Makefile", "all:\n")

    assert {:ok, %{modules: ["Elixir.HmR52B"]}} =
             all |> Map.put("priv/templates/t.ex", template) |> tarball() |> HexModules.read()

    assert {:error, {:unparsed, "test/x.ex"}} =
             all |> Map.put("test/x.ex", "defmodule (") |> tarball() |> HexModules.read()
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
