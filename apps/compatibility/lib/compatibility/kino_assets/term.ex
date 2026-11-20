defmodule Compatibility.KinoAssets.Term do
  @moduledoc """
  The Erlang external term format, read without making an atom: each atom
  comes back as `{:atom, name}`, its name as bytes, so a term a package's
  compile wrote (a beam's `Dbgi` chunk, `Compatibility.KinoAssets`) can be
  read on a node that lives on across ingests, which never frees an atom.
  A real atom never appears in the result, so `{:atom, name}` is never data.

  Only what Elixir's debug info holds is read: integers, floats, atoms,
  binaries, bit strings, tuples, lists (improper ones too), maps, and a
  compressed term (inflated to at most `max_bytes`). A pid, a port, a
  reference, a fun, an atom cache reference or nesting deeper than 10,000
  is `:error`, and so is any byte past the term. Never raises.
  """

  @max_depth 10_000

  @doc "The term in `bytes`, atoms as `{:atom, name}`, or `:error`."
  @spec decode(binary(), pos_integer()) :: {:ok, term()} | :error
  def decode(<<131, 80, size::32, zlib::binary>>, max_bytes) when size <= max_bytes do
    with {:ok, plain} <- inflate(zlib, size), do: decode(<<131>> <> plain, max_bytes)
  end

  def decode(<<131, rest::binary>>, _max_bytes) do
    case value(rest, 0) do
      {:ok, term, <<>>} -> {:ok, term}
      _ -> :error
    end
  catch
    :error -> :error
  end

  def decode(_bytes, _max_bytes), do: :error

  # Exactly `size` bytes out, never more: a stream that would give more, or
  # fewer, is no term.
  defp inflate(zlib, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflate_loop(z, :zlib.safeInflate(z, zlib), [], 0, size)
    catch
      _kind, _reason -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, out}, acc, got, size) when state in [:continue, :finished] do
    got = got + IO.iodata_length(out)

    cond do
      got > size -> :error
      state == :finished and got == size -> {:ok, IO.iodata_to_binary([acc, out])}
      state == :finished -> :error
      true -> inflate_loop(z, :zlib.safeInflate(z, []), [acc, out], got, size)
    end
  end

  defp inflate_loop(_z, _other, _acc, _got, _size), do: :error

  defp value(_bytes, depth) when depth > @max_depth, do: throw(:error)
  defp value(<<97, n, rest::binary>>, _depth), do: {:ok, n, rest}
  defp value(<<98, n::signed-32, rest::binary>>, _depth), do: {:ok, n, rest}
  defp value(<<70, f::float-64, rest::binary>>, _depth), do: {:ok, f, rest}

  defp value(<<110, n, sign, digits::binary-size(n), rest::binary>>, _depth),
    do: {:ok, big(sign, digits), rest}

  defp value(<<111, n::32, sign, digits::binary-size(n), rest::binary>>, _depth),
    do: {:ok, big(sign, digits), rest}

  defp value(<<tag, len::16, name::binary-size(len), rest::binary>>, _depth)
       when tag in [100, 118],
       do: {:ok, {:atom, name}, rest}

  defp value(<<tag, len, name::binary-size(len), rest::binary>>, _depth) when tag in [115, 119],
    do: {:ok, {:atom, name}, rest}

  defp value(<<106, rest::binary>>, _depth), do: {:ok, [], rest}

  defp value(<<107, len::16, chars::binary-size(len), rest::binary>>, _depth),
    do: {:ok, :binary.bin_to_list(chars), rest}

  defp value(<<109, len::32, bin::binary-size(len), rest::binary>>, _depth), do: {:ok, bin, rest}

  defp value(<<77, len::32, bits, bin::binary-size(len), rest::binary>>, _depth)
       when len > 0 and bits in 1..8 do
    keep = (len - 1) * 8 + bits
    <<bitstring::bitstring-size(^keep), _::bitstring>> = bin
    {:ok, bitstring, rest}
  end

  defp value(<<104, arity, rest::binary>>, depth), do: tuple(rest, arity, depth)
  defp value(<<105, arity::32, rest::binary>>, depth), do: tuple(rest, arity, depth)

  defp value(<<108, len::32, rest::binary>>, depth) do
    {items, rest} = items(rest, len, depth + 1, [])
    {:ok, tail, rest} = value(rest, depth + 1)
    {:ok, improper(items, tail), rest}
  end

  defp value(<<116, arity::32, rest::binary>>, depth) do
    {items, rest} = items(rest, 2 * arity, depth + 1, [])
    pairs = items |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {k, v} end)
    {:ok, Map.new(pairs), rest}
  end

  defp value(_bytes, _depth), do: throw(:error)

  defp tuple(rest, arity, depth) do
    {items, rest} = items(rest, arity, depth + 1, [])
    {:ok, List.to_tuple(items), rest}
  end

  # Each item takes at least one byte, so a count past the bytes left is no
  # term, before anything is built for it.
  defp items(rest, n, _depth, _acc) when n > byte_size(rest), do: throw(:error)
  defp items(rest, 0, _depth, acc), do: {Enum.reverse(acc), rest}

  defp items(bytes, n, depth, acc) do
    {:ok, item, rest} = value(bytes, depth)
    items(rest, n - 1, depth, [item | acc])
  end

  defp improper(items, []), do: items
  defp improper(items, tail), do: List.foldr(items, tail, &[&1 | &2])

  defp big(sign, digits) do
    n = digits |> :binary.bin_to_list() |> Enum.reverse() |> Enum.reduce(0, &(&2 * 256 + &1))
    if sign == 0, do: n, else: -n
  end
end
