defmodule NccWorker.BuildIdentityTest do
  use ExUnit.Case, async: true

  alias NccWorker.BuildIdentity

  defp beam do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule NccWorker.BuildIdentityTest.Sample do
        @moduledoc "Sample."
        @doc "One."
        def one, do: 1
      end
      """)

    bin
  end

  defp chunks(bin) do
    {:ok, _mod, chunks} = :beam_lib.all_chunks(bin)
    chunks
  end

  defp build(chunks) do
    {:ok, bin} = :beam_lib.build_module(chunks)
    bin
  end

  # The beam with chunk `id`'s payload replaced by `fun.(payload)`.
  defp with_chunk(bin, id, fun) do
    bin
    |> chunks()
    |> Enum.map(fn {i, p} -> if i == id, do: {i, fun.(p)}, else: {i, p} end)
    |> build()
  end

  # The same term, encoded with other bytes: the compressed external form,
  # which `term_to_binary/2` itself only writes when it is smaller.
  defp reencode(payload) do
    <<131, raw::binary>> = :erlang.term_to_binary(:erlang.binary_to_term(payload))
    other = <<131, 80, byte_size(raw)::32, :zlib.compress(raw)::binary>>
    true = :erlang.binary_to_term(other) === :erlang.binary_to_term(payload)
    if other != payload, do: other, else: <<131>> <> raw
  end

  # A Docs chunk, added when the test VM compiles without docs.
  defp with_docs(bin) do
    if List.keymember?(chunks(bin), ~c"Docs", 0) do
      bin
    else
      docs = {:docs_v1, 1, :elixir, "text/markdown", %{"en" => "Sample."}, %{}, []}
      build(chunks(bin) ++ [{~c"Docs", :erlang.term_to_binary(docs, compressed: 9)}])
    end
  end

  defp flip_last(payload) do
    size = byte_size(payload) - 1
    <<head::binary-size(size), last>> = payload
    head <> <<Bitwise.bxor(last, 1)>>
  end

  test "identical builds have no differences" do
    b = beam()
    files = %{"a/ebin/x.beam" => b, "a/priv/x.txt" => "x"}
    assert BuildIdentity.differences(files, files) == []
  end

  test "a Dbgi chunk that encodes the same term differently is identical" do
    b = beam()
    other = with_chunk(b, ~c"Dbgi", &reencode/1)
    assert other != b
    assert BuildIdentity.beam_difference(b, other) == nil
  end

  test "a Dbgi chunk that decodes to another term differs" do
    b = beam()

    other =
      with_chunk(b, ~c"Dbgi", fn p ->
        {:debug_info_v1, backend, data} = :erlang.binary_to_term(p)
        :erlang.term_to_binary({:debug_info_v1, backend, {:changed, data}})
      end)

    assert BuildIdentity.beam_difference(b, other) == {:chunk_differs, "Dbgi"}
  end

  test "a tampered Code byte differs" do
    b = beam()
    other = with_chunk(b, ~c"Code", &flip_last/1)
    assert BuildIdentity.beam_difference(b, other) == {:chunk_differs, "Code"}
  end

  test "a docs chunk that encodes the same term differently still differs" do
    b = with_docs(beam())
    other = with_chunk(b, ~c"Docs", &reencode/1)
    assert other != b
    assert BuildIdentity.beam_difference(b, other) == {:chunk_differs, "Docs"}
  end

  test "the same chunks in another order differ" do
    b = beam()
    other = b |> chunks() |> Enum.reverse() |> build()
    assert {:chunk_ids_differ, _, _} = BuildIdentity.beam_difference(b, other)
  end

  test "an extra chunk differs" do
    b = beam()
    other = build(chunks(b) ++ [{~c"Xtra", <<1, 2, 3>>}])
    assert {:chunk_ids_differ, ids, other_ids} = BuildIdentity.beam_difference(b, other)
    assert other_ids == ids ++ [~c"Xtra"]
  end

  test "a missing chunk differs" do
    b = beam()
    other = b |> chunks() |> List.keydelete(~c"Line", 0) |> build()
    assert {:chunk_ids_differ, ids, other_ids} = BuildIdentity.beam_difference(b, other)
    assert other_ids == List.delete(ids, ~c"Line")
  end

  test "a file only the second build has differs" do
    assert BuildIdentity.differences(%{}, %{"a/ebin/a.app" => "{}"}) ==
             [{"a/ebin/a.app", :only_in_second}]
  end

  test "a non-beam file is compared byte for byte, and a missing file differs" do
    a = %{"a/priv/x.txt" => "x", "a/ebin/a.app" => "{}"}
    b = %{"a/priv/x.txt" => "y"}

    assert BuildIdentity.differences(a, b) == [
             {"a/ebin/a.app", :only_in_first},
             {"a/priv/x.txt", :bytes_differ}
           ]
  end
end
