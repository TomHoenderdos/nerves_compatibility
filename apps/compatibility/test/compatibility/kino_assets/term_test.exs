defmodule Compatibility.KinoAssets.TermTest do
  use ExUnit.Case, async: true

  alias Compatibility.KinoAssets.Term

  @max 64 * 1024 * 1024

  # What `Term.decode/2` gives for `term`: every atom as `{:atom, name}`.
  defp wrapped(term) when is_atom(term), do: {:atom, Atom.to_string(term)}

  defp wrapped(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&wrapped/1) |> List.to_tuple()

  defp wrapped(term) when is_map(term),
    do: Map.new(term, fn {k, v} -> {wrapped(k), wrapped(v)} end)

  defp wrapped([head | tail]), do: [wrapped(head) | wrapped(tail)]
  defp wrapped(term), do: term

  test "every shape debug info holds reads as binary_to_term reads it, atoms as names" do
    terms = [
      0,
      255,
      -1,
      2_147_483_647,
      -2_147_483_648,
      2 ** 64,
      -(2 ** 300),
      3.25,
      -0.0,
      :ok,
      :"Elixir.Kino.VegaLite",
      :ünïcødé,
      String.to_atom(String.duplicate("a", 255)),
      "",
      "bytes",
      <<1::3>>,
      <<255, 7::5>>,
      [],
      [1, 2, 3],
      ~c"chars",
      [1 | 2],
      [:a, :b | :c],
      {},
      {:def, [line: 1], nil},
      List.to_tuple(Enum.to_list(1..300)),
      %{},
      %{definitions: [{{:__assets_info__, 0}, :def, [], []}], file: "x"},
      Map.new(1..40, &{&1, Integer.to_string(&1)}),
      Enum.to_list(1..1000)
    ]

    for term <- terms, compressed? <- [false, true] do
      bytes = :erlang.term_to_binary(term, if(compressed?, do: [compressed: 9], else: []))
      assert Term.decode(bytes, @max) == {:ok, wrapped(term)}, inspect({term, compressed?})
    end
  end

  test "pids, ports, references and funs are no term, nor are trailing bytes" do
    for term <- [self(), make_ref(), fn -> :x end, &Enum.map/2, Port.list() |> List.first()],
        term != nil do
      assert Term.decode(:erlang.term_to_binary(term), @max) == :error, inspect(term)
    end

    assert Term.decode(:erlang.term_to_binary(:ok) <> "x", @max) == :error
    assert Term.decode(<<>>, @max) == :error
    assert Term.decode("not a term", @max) == :error
  end

  test "a compressed term inflates only to its own size, and only under the cap" do
    big = :erlang.term_to_binary(:binary.copy(<<0>>, 100_000), [:compressed])
    assert {:ok, _} = Term.decode(big, @max)
    assert Term.decode(big, 1000) == :error

    <<131, 80, size::32, zlib::binary>> = big
    assert Term.decode(<<131, 80, size - 1::32>> <> zlib, @max) == :error
    assert Term.decode(<<131, 80, size + 1::32>> <> zlib, @max) == :error
  end

  test "nesting past 10,000 is no term" do
    deep = Enum.reduce(1..10_001, :leaf, fn _, acc -> {acc} end)
    assert Term.decode(:erlang.term_to_binary(deep), @max) == :error
    shallow = Enum.reduce(1..9_000, :leaf, fn _, acc -> {acc} end)
    assert {:ok, _} = Term.decode(:erlang.term_to_binary(shallow), @max)
  end

  test "truncated and random bytes are :error, never a raise" do
    good = :erlang.term_to_binary(%{a: [1, "two", {:three, 4.0}]})

    for n <- 1..(byte_size(good) - 1) do
      assert Term.decode(binary_part(good, 0, n), @max) == :error, inspect(n)
    end

    for _ <- 1..500 do
      junk = <<131>> <> :crypto.strong_rand_bytes(:rand.uniform(64))
      assert Term.decode(junk, @max) in [:error] or match?({:ok, _}, Term.decode(junk, @max))
    end

    # A count no bytes could hold builds nothing.
    assert Term.decode(<<131, 108, 0xFFFFFFFF::32>>, @max) == :error
    assert Term.decode(<<131, 116, 0xFFFFFFFF::32>>, @max) == :error
    assert Term.decode(<<131, 105, 0xFFFFFFFF::32>>, @max) == :error
  end
end
