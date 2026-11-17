defmodule Compatibility.DeterministicBeamsTest do
  use ExUnit.Case, async: true

  alias Compatibility.DeterministicBeams

  @moduletag :tmp_dir

  # An Elixir module compiled twice in this VM, with and without the option.
  # `@compile :deterministic` gives the beam the env var gives (design,
  # section 2); the env var itself is read once per VM.
  defp elixir_pair(name, body, sibling_body \\ nil) do
    module = Module.concat([DeterministicBeamsTest, name])
    normal = compile_elixir(module, "", body)
    sibling = compile_elixir(module, "@compile :deterministic", sibling_body || body)
    {normal, sibling}
  end

  defp compile_elixir(module, attr, body) do
    source = "defmodule #{inspect(module)} do #{attr}\n#{body}\nend\n"
    [{^module, beam}] = Code.compile_string(source, "lib/fixture.ex")
    :code.delete(module)
    :code.purge(module)
    beam
  end

  defp erlang_pair(dir, name, body) do
    path = Path.join(dir, "#{name}.erl")
    File.write!(path, "-module(#{name}).\n-export([f/0]).\n" <> body)
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  test "an Elixir module whose sibling differs only in its metadata passes" do
    {normal, sibling} = elixir_pair(Plain, ~s|@moduledoc "x"\ndef f(x), do: {x, __ENV__.file}|)

    assert normal != sibling
    assert DeterministicBeams.compare_beam(normal, sibling) == :ok
  end

  test "an Erlang module whose ?FILE literal changed passes; its md5 differs", %{tmp_dir: dir} do
    {normal, sibling} = erlang_pair(dir, "fx_file", "f() -> ?FILE.\n")

    assert :beam_lib.md5(normal) != :beam_lib.md5(sibling)
    assert DeterministicBeams.compare_beam(normal, sibling) == :ok
  end

  test "a sibling the option never reached is refused" do
    {normal, _sibling} = elixir_pair(NotReached, "def f, do: 1")

    assert DeterministicBeams.compare_beam(normal, normal) ==
             {:error, "not compiled with the option"}
  end

  test "an Elixir sibling whose code differs is refused" do
    {normal, sibling} = elixir_pair(Code, "def f, do: 1", "def f, do: 2")

    assert {:error, "chunks " <> ids} = DeterministicBeams.compare_beam(normal, sibling)
    assert ids =~ "Code"
  end

  test "an Elixir sibling whose literals alone differ is refused" do
    {normal, sibling} = elixir_pair(Lit, ~s|def f, do: {:ok, "a"}|, ~s|def f, do: {:ok, "b"}|)

    assert {:error, _} = DeterministicBeams.compare_beam(normal, sibling)
  end

  test "an Erlang sibling whose code differs is refused", %{tmp_dir: dir} do
    {normal, _} = erlang_pair(dir, "fx_code", "f() -> 1.\n")
    {_, sibling} = erlang_pair(dir, "fx_code", "f() -> 2.\n")

    assert {:error, "chunks " <> ids} = DeterministicBeams.compare_beam(normal, sibling)
    assert ids =~ "Code"
  end

  test "another module, or bytes that are no beam, are refused without raising",
       %{tmp_dir: dir} do
    {a, _} = erlang_pair(dir, "fx_a", "f() -> ok.\n")
    {_, b} = erlang_pair(dir, "fx_b", "f() -> ok.\n")

    assert DeterministicBeams.compare_beam(a, b) == {:error, "another module"}
    assert DeterministicBeams.compare_beam("nope", b) == {:error, "unreadable beam"}
    assert DeterministicBeams.compare_beam(a, nil) == {:error, "unreadable beam"}
  end

  describe "compare_ebin/2" do
    setup %{tmp_dir: dir} do
      {normal, sibling} = erlang_pair(dir, "fx_ebin", "f() -> ?FILE.\n")
      app = ~s|{application,fx_ebin,[{vsn,"0.1.0"}]}.\n|
      %{normal: %{"fx_ebin.beam" => normal, "fx_ebin.app" => app}, sibling: sibling, app: app}
    end

    test "the same names, the same .app and checked beams pass", ctx do
      sibling = %{ctx.normal | "fx_ebin.beam" => ctx.sibling}
      assert DeterministicBeams.compare_ebin(ctx.normal, sibling) == :ok
    end

    test "another file set, a changed .app or a refused beam fail, naming the file", ctx do
      sibling = %{ctx.normal | "fx_ebin.beam" => ctx.sibling}

      assert DeterministicBeams.compare_ebin(ctx.normal, Map.delete(sibling, "fx_ebin.app")) ==
               {:error, "the sibling's ebin holds other files"}

      assert DeterministicBeams.compare_ebin(ctx.normal, %{sibling | "fx_ebin.app" => "x"}) ==
               {:error, "fx_ebin.app: differs"}

      assert DeterministicBeams.compare_ebin(ctx.normal, ctx.normal) ==
               {:error, "fx_ebin.beam: not compiled with the option"}

      assert DeterministicBeams.compare_ebin(%{}, %{}) == {:error, "no ebin files"}
    end
  end
end
