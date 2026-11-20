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

  # A LARGE_BIG_EXT of `digits` little-endian bytes.
  defp large_big(digits, sign \\ 0), do: <<131, 111, byte_size(digits)::32, sign>> <> digits

  # R-2: the largest integer in the debug info of 6,074 real beams (Elixir,
  # OTP, the umbrella's deps) is 1,024 bytes, an 8192-bit prime in OTP's
  # pubkey_ssh. 64 KiB of digits is the cap; up to it an integer reads in
  # linear time, as `binary_to_term` reads it.
  test "a large integer up to the cap reads in linear time, as binary_to_term reads it" do
    digits = :crypto.strong_rand_bytes(64 * 1024)

    for sign <- [0, 1] do
      bytes = large_big(digits, sign)
      {micros, result} = :timer.tc(fn -> Term.decode(bytes, @max) end)
      assert result == {:ok, :erlang.binary_to_term(bytes)}
      assert micros < 100_000, "#{micros} µs"
    end

    assert Term.decode(:erlang.term_to_binary(2 ** 8191 + 1), @max) == {:ok, 2 ** 8191 + 1}
  end

  test "an integer past the cap is no term" do
    assert Term.decode(large_big(:binary.copy(<<1>>, 64 * 1024 + 1)), @max) == :error
  end

  # Zero digits compress to almost nothing, so a tiny beam can carry one.
  @tag timeout: 10_000
  test "a huge compressed integer is refused at once, never decoded" do
    # 16 MiB of zero digits and a one: 2 ** (8 * 16 MiB), as
    # `term_to_binary(_, [:compressed])` writes it.
    digits = :binary.copy(<<0>>, 16 * 1024 * 1024) <> <<1>>
    plain = <<111, byte_size(digits)::32, 0>> <> digits
    bytes = <<131, 80, byte_size(plain)::32>> <> :zlib.compress(plain)
    assert byte_size(bytes) < 100_000
    {micros, result} = :timer.tc(fn -> Term.decode(bytes, @max) end)
    assert result == :error
    assert micros < 2_000_000, "#{micros} µs"
  end

  # R-3: `binary_to_term` refuses a map whose keys repeat; so does `Term`.
  test "a map with a repeated key is no term" do
    dup = <<131, 116, 2::32, 97, 1, 97, 2, 97, 1, 97, 3>>
    assert_raise ArgumentError, fn -> :erlang.binary_to_term(dup) end
    assert Term.decode(dup, @max) == :error

    atom_dup = <<131, 116, 2::32, 119, 1, "k", 97, 2, 119, 1, "k", 97, 3>>
    assert_raise ArgumentError, fn -> :erlang.binary_to_term(atom_dup) end
    assert Term.decode(atom_dup, @max) == :error

    fine = <<131, 116, 2::32, 97, 1, 97, 2, 97, 3, 97, 4>>
    assert Term.decode(fine, @max) == {:ok, :erlang.binary_to_term(fine)}
  end
end
