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

  # `beam` with chunk `id` rewritten by `fun`, rebuilt uncompressed.
  defp rewrite_chunk(beam, id, fun) do
    {:ok, _, chunks} = :beam_lib.all_chunks(beam)
    key = String.to_charlist(id)

    chunks
    |> Enum.map(fn
      {^key, bytes} -> {key, fun.(bytes)}
      chunk -> chunk
    end)
    |> :beam_lib.build_module()
    |> elem(1)
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

  # telemetry_poller: a `?LOG_*` (`?FILE`) and a fun in one module. The
  # compiler takes each fun's `old_uniq` in `FunT` from the module's md5,
  # which the literal changed.
  test "an Erlang module with a ?FILE literal and a fun passes; FunT's uniq alone differs",
       %{tmp_dir: dir} do
    body = "-export([g/2]).\nf() -> ?FILE.\ng(X, L) -> lists:map(fun(Y) -> {X, Y} end, L).\n"
    {normal, sibling} = erlang_pair(dir, "fx_fun", body)

    {:ok, _, a} = :beam_lib.all_chunks(normal)
    {:ok, _, b} = :beam_lib.all_chunks(sibling)
    refute List.keyfind(a, ~c"FunT", 0) == List.keyfind(b, ~c"FunT", 0)
    assert DeterministicBeams.compare_beam(normal, sibling) == :ok
  end

  test "a FunT that differs in more than the funs' uniq is refused", %{tmp_dir: dir} do
    body = "-export([g/2]).\nf() -> ?FILE.\ng(X, L) -> lists:map(fun(Y) -> {X, Y} end, L).\n"
    {normal, sibling} = erlang_pair(dir, "fx_fun2", body)

    # The fun's arity (its second word) changed, its uniq kept.
    tampered =
      rewrite_chunk(sibling, "FunT", fn <<n::32, name::32, _arity::32, rest::binary>> ->
        <<n::32, name::32, 7::32, rest::binary>>
      end)

    assert {:error, "chunks FunT differ"} = DeterministicBeams.compare_beam(normal, tampered)
  end

  test "an Elixir module whose FunT differs is refused" do
    {normal, sibling} =
      elixir_pair(FunT, "def f(l), do: Enum.map(l, &g/1)\ndef g(x), do: x")

    tampered =
      rewrite_chunk(sibling, "FunT", fn <<n::32, keep::binary-size(20), uniq::32>> ->
        <<n::32, keep::binary, uniq + 1::32>>
      end)

    assert {:error, "chunks FunT differ"} = DeterministicBeams.compare_beam(normal, tampered)
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

  describe "untrusted beams (the portal checks them on its own long-lived node)" do
    # A name no module of this VM has, so its atom does not exist yet.
    defp fresh_name(prefix),
      do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    # A deterministic beam of `Fresh000000000000`, rebuilt with its first
    # atom (the module's name) renamed to `module_name`, a name of the same
    # length, and its `Dbgi` replaced by `dbgi`; `cinf` replaces its `CInf`
    # when given. Built with `:beam_lib.build_module/1`, which reads no term.
    defp rebuilt(module_name, dbgi, cinf \\ nil) do
      placeholder = "Elixir.DeterministicBeamsTest.Fresh000000000000"
      true = byte_size(placeholder) == byte_size(module_name)
      module = String.to_atom(placeholder)
      sibling = compile_elixir(module, "@compile :deterministic", "def f(v), do: v")
      {:ok, _, chunks} = :beam_lib.all_chunks(sibling)

      chunks =
        for {id, data} <- chunks do
          case id do
            ~c"AtU8" -> {id, :binary.replace(data, placeholder, module_name)}
            ~c"Dbgi" -> {id, dbgi}
            ~c"CInf" when is_binary(cinf) -> {id, cinf}
            _ -> {id, data}
          end
        end

      {:ok, beam} = :beam_lib.build_module(chunks)
      beam
    end

    defp atom(name), do: <<119, byte_size(name)>> <> name

    test "checking a beam creates no atom, its module's name or its debug info's" do
      module_name = fresh_name("Elixir.DeterministicBeamsTest.Fresh")
      inner = fresh_name("ncc_fresh_")
      dbgi = <<131, 104, 3>> <> atom("debug_info_v1") <> atom("elixir_erl") <> atom(inner)
      beam = rebuilt(module_name, dbgi)

      assert DeterministicBeams.compare_beam(beam, beam) == :ok
      assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(inner) end
    end

    test "a compile info naming an atom this VM lacks is refused, and creates none" do
      module_name = fresh_name("Elixir.DeterministicBeamsTest.Fresh")
      inner = fresh_name("ncc_fresh_")
      dbgi = <<131, 104, 3>> <> atom("debug_info_v1") <> atom("elixir_erl") <> atom("none")

      cinf =
        <<131, 108, 2::32, 104, 2>> <>
          atom("version") <> <<107, 1::16, ?9, 104, 2>> <> atom(inner) <> <<97, 1, 106>>

      beam = rebuilt(module_name, dbgi, cinf)

      assert {:error, _} = DeterministicBeams.compare_beam(beam, beam)
      assert_raise ArgumentError, fn -> String.to_existing_atom(inner) end
    end

    test "a gzip-compressed beam is refused, never inflated" do
      {normal, sibling} = elixir_pair(Gzipped, "def f, do: 1")

      assert DeterministicBeams.compare_beam(:zlib.gzip(normal), :zlib.gzip(sibling)) ==
               {:error, "unreadable beam"}
    end

    test "a compressed debug info is read for its backend alone", %{tmp_dir: dir} do
      # Only an Erlang module may differ in Line and LitT, so this passes
      # only when the backend is read out of the compressed Dbgi.
      {normal, sibling} = erlang_pair(dir, "fx_dbgi", "f() -> ?FILE.\n")

      {:ok, _, chunks} = :beam_lib.all_chunks(sibling)
      assert <<131, 80, _::binary>> = :proplists.get_value(~c"Dbgi", chunks)
      assert DeterministicBeams.compare_beam(normal, sibling) == :ok
    end
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
