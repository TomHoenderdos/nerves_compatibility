defmodule NccWorker.Portability.DifferentialBeamsTest do
  # `DifferentialBeams.compare_app/3` on real beams compiled twice, at two
  # roots of the same length, with and without a value changed; and on
  # beams whose skipped or residue chunks were rewritten by hand.
  use ExUnit.Case, async: false

  alias NccWorker.Portability.DifferentialBeams

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    a = Path.join(dir, "root_a")
    b = Path.join(dir, "root_b")
    %{dir: dir, a: a, b: b, roots: {a, b}}
  end

  # An app dir `<root>/lib/pkg` holding `beams` (`name => bytes`) and a `.app`.
  defp app(root, beams, extra \\ %{}) do
    ebin = Path.join(root, "lib/pkg/ebin")
    File.mkdir_p!(ebin)

    files =
      Map.merge(%{"pkg.app" => ~s({application,pkg,[{vsn,"0.1.0"}]}.\n)}, beams)
      |> Map.merge(extra)

    for {name, bytes} <- files, do: File.write!(Path.join(ebin, name), bytes)
    Path.join(root, "lib/pkg")
  end

  # An Elixir module compiled from `body` as if from `<root>/lib/pkg.ex`.
  defp elixir(root, body) do
    Code.put_compiler_option(:ignore_module_conflict, true)
    # Mix's test VM may compile without docs; a real compile writes them.
    docs = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)
    source = "defmodule DiffBeamsFixture do\n#{body}\nend\n"
    [{mod, bin}] = Code.compile_string(source, Path.join(root, "lib/pkg.ex"))
    :code.purge(mod)
    :code.delete(mod)
    Code.put_compiler_option(:docs, docs)
    %{"Elixir.DiffBeamsFixture.beam" => bin}
  after
    Code.put_compiler_option(:ignore_module_conflict, false)
  end

  # An Erlang module whose `f/0` returns its own source path (`?FILE`).
  defp erlang(root, body \\ "f() -> ?FILE.") do
    src = Path.join(root, "src/diff_beams_erl.erl")
    File.mkdir_p!(Path.dirname(src))
    File.write!(src, "-module(diff_beams_erl).\n-export([f/0]).\n#{body}\n")
    {:ok, :diff_beams_erl, bin} = :compile.file(String.to_charlist(src), [:binary, :debug_info])
    %{"diff_beams_erl.beam" => bin}
  end

  defp chunks(<<"FOR1", _::32, "BEAM", rest::binary>>), do: read(rest, [])

  defp read(<<>>, acc), do: Enum.reverse(acc)

  defp read(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)
    <<_::binary-size(^pad), rest::binary>> = rest
    read(rest, [{id, data} | acc])
  end

  defp beam(chunks) do
    body =
      for {id, data} <- chunks, into: <<>> do
        pad = rem(4 - rem(byte_size(data), 4), 4)
        <<id::binary, byte_size(data)::32, data::binary, 0::size(pad)-unit(8)>>
      end

    <<"FOR1", byte_size(body) + 4::32, "BEAM", body::binary>>
  end

  # The beam with chunk `id` passed through `fun`.
  defp rewrite(bin, id, fun) do
    bin
    |> chunks()
    |> Enum.map(fn
      {^id, d} -> {id, fun.(d)}
      other -> other
    end)
    |> beam()
  end

  defp only(beams), do: beams |> Map.values() |> hd()

  # Elixir writes its line table's file relative to the cwd, so the roots
  # here are the two dir names, which both the literal and that path hold.
  test "the same source at two roots of the same length is the same app", ctx do
    first = app(ctx.a, elixir(ctx.a, "def x, do: __DIR__"))
    variant = app(ctx.b, elixir(ctx.b, "def x, do: __DIR__"))

    assert DifferentialBeams.compare_app(first, variant, {"root_a", "root_b"}) == :ok
    # Without the roots the path in the literals is a difference.
    assert {:differs, "ebin/Elixir.DiffBeamsFixture.beam: " <> _} =
             DifferentialBeams.compare_app(first, variant, nil)
  end

  test "an Erlang module's ?FILE at the other root is the same", ctx do
    first = app(ctx.a, erlang(ctx.a))
    variant = app(ctx.b, erlang(ctx.b))
    assert DifferentialBeams.compare_app(first, variant, ctx.roots) == :ok
    assert {:differs, _} = DifferentialBeams.compare_app(first, variant, {ctx.a, ctx.b <> "x"})
  end

  test "a value baked into a function differs", ctx do
    first = app(ctx.a, elixir(ctx.a, "@n 1\ndef n, do: @n"))
    variant = app(ctx.b, elixir(ctx.b, "@n 128\ndef n, do: @n"))

    assert {:differs, "ebin/Elixir.DiffBeamsFixture.beam: " <> chunks} =
             DifferentialBeams.compare_app(first, variant, ctx.roots)

    assert chunks =~ "Code" or chunks =~ "LitT"
  end

  test "docs and persisted attributes are compared, not stripped", ctx do
    first = app(ctx.a, elixir(ctx.a, ~s(@moduledoc "one")))
    variant = app(ctx.b, elixir(ctx.b, ~s(@moduledoc "two")))

    assert {:differs, "ebin/Elixir.DiffBeamsFixture.beam: Docs"} =
             DifferentialBeams.compare_app(first, variant, ctx.roots)

    persisted = "Module.register_attribute(__MODULE__, :n, persist: true)\n@n "
    first = app(Path.join(ctx.a, "p"), elixir(ctx.a, persisted <> "1"))
    variant = app(Path.join(ctx.b, "p"), elixir(ctx.b, persisted <> "2"))

    assert {:differs, "ebin/Elixir.DiffBeamsFixture.beam: " <> chunks} =
             DifferentialBeams.compare_app(first, variant, {ctx.a, ctx.b})

    assert chunks =~ "Attr"
  end

  test "CInf, Dbgi and ExCk are skipped", ctx do
    bin = ctx.a |> elixir("def x, do: 1") |> only()
    first = app(ctx.a, %{"Elixir.DiffBeamsFixture.beam" => bin})

    for id <- ~w(CInf Dbgi ExCk) do
      other = rewrite(bin, id, &(&1 <> "x"))
      variant = app(Path.join(ctx.b, id), %{"Elixir.DiffBeamsFixture.beam" => other})
      assert DifferentialBeams.compare_app(first, variant, nil) == :ok, id
    end

    other = rewrite(bin, "Line", &(&1 <> <<0>>))
    variant = app(Path.join(ctx.b, "line"), %{"Elixir.DiffBeamsFixture.beam" => other})
    assert {:differs, _} = DifferentialBeams.compare_app(first, variant, nil)
  end

  test "FunT may differ in old_uniq alone", ctx do
    bin = ctx.a |> elixir("def f, do: fn -> 1 end") |> only()
    first = app(ctx.a, %{"Elixir.DiffBeamsFixture.beam" => bin})

    uniq = fn <<n::32, t::binary>> ->
      <<n::32>> <> for(<<k::binary-size(20), u::32 <- t>>, into: <<>>, do: k <> <<u + 1::32>>)
    end

    variant =
      app(Path.join(ctx.b, "u"), %{"Elixir.DiffBeamsFixture.beam" => rewrite(bin, "FunT", uniq)})

    assert DifferentialBeams.compare_app(first, variant, nil) == :ok

    label = fn <<n::32, f::32, rest::binary>> -> <<n::32, f + 1::32, rest::binary>> end

    variant =
      app(Path.join(ctx.b, "l"), %{"Elixir.DiffBeamsFixture.beam" => rewrite(bin, "FunT", label)})

    assert {:differs, _} = DifferentialBeams.compare_app(first, variant, nil)
  end

  test "Attr may differ in the vsn md5 alone", ctx do
    bin = ctx.a |> erlang("f() -> ok.") |> only()
    first = app(ctx.a, %{"diff_beams_erl.beam" => bin})
    {_, attr} = bin |> chunks() |> List.keyfind("Attr", 0)
    [{:vsn, [md5]}] = Keyword.take(:erlang.binary_to_term(attr), [:vsn])
    other = :erlang.term_to_binary([{:vsn, [md5 + 1]}])
    assert other != attr

    variant =
      app(Path.join(ctx.b, "v"), %{
        "diff_beams_erl.beam" => rewrite(bin, "Attr", fn _ -> other end)
      })

    assert DifferentialBeams.compare_app(first, variant, nil) == :ok

    other = :erlang.term_to_binary([{:vsn, [md5]}, {:n, [1]}])

    variant =
      app(Path.join(ctx.b, "n"), %{
        "diff_beams_erl.beam" => rewrite(bin, "Attr", fn _ -> other end)
      })

    assert {:differs, _} = DifferentialBeams.compare_app(first, variant, nil)
  end

  test "another file set, another .app or another priv differs", ctx do
    beams = elixir(ctx.a, "def x, do: 1")
    first = app(ctx.a, beams)

    assert {:differs, "ebin holds other files"} =
             DifferentialBeams.compare_app(
               first,
               app(Path.join(ctx.b, "1"), beams, %{"x.beam" => "x"}),
               nil
             )

    assert {:differs, "ebin/pkg.app: differs"} =
             DifferentialBeams.compare_app(
               first,
               app(Path.join(ctx.b, "2"), beams, %{"pkg.app" => "{application,pkg,[]}.\n"}),
               nil
             )

    File.mkdir_p!(Path.join(first, "priv"))
    File.write!(Path.join(first, "priv/a.txt"), "a")
    variant = app(Path.join(ctx.b, "3"), beams)
    File.mkdir_p!(Path.join(variant, "priv"))
    File.write!(Path.join(variant, "priv/a.txt"), "b")
    assert {:differs, "priv/a.txt: differs"} = DifferentialBeams.compare_app(first, variant, nil)

    File.write!(Path.join(variant, "priv/a.txt"), "a")
    assert DifferentialBeams.compare_app(first, variant, nil) == :ok
    File.chmod!(Path.join(variant, "priv/a.txt"), 0o755)

    assert {:differs, "priv/a.txt: other permissions"} =
             DifferentialBeams.compare_app(first, variant, nil)
  end

  test "a priv link is compared by its target", ctx do
    beams = elixir(ctx.a, "def x, do: 1")
    first = app(ctx.a, beams)
    variant = app(ctx.b, beams)
    File.ln_s!(Path.join(ctx.dir, "deps/pkg/priv"), Path.join(first, "priv"))
    File.ln_s!(Path.join(ctx.dir, "deps/pkg/priv"), Path.join(variant, "priv"))
    assert DifferentialBeams.compare_app(first, variant, ctx.roots) == :ok

    File.rm!(Path.join(variant, "priv"))
    File.ln_s!(Path.join(ctx.dir, "deps/other/priv"), Path.join(variant, "priv"))

    assert {:differs, "priv: another link target"} =
             DifferentialBeams.compare_app(first, variant, ctx.roots)
  end

  test "an unreadable beam or a missing ebin is no match", ctx do
    first = app(ctx.a, %{"m.beam" => "not a beam"})
    variant = app(ctx.b, %{"m.beam" => "not a beam either"})

    assert {:error, "ebin/m.beam: unreadable beam"} =
             DifferentialBeams.compare_app(first, variant, nil)

    assert {:error, _} = DifferentialBeams.compare_app(first, Path.join(ctx.dir, "none"), nil)
  end
end
