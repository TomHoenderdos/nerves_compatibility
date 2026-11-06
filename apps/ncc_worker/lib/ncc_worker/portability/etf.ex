defmodule NccWorker.Portability.Etf do
  @moduledoc """
  A bounded reader for the external term format that creates no atoms, for
  literal tables and attribute chunks of beams the worker did not write
  (`NccWorker.Portability.BuildRoot`). `binary_to_term(_, [:safe])` would
  refuse almost every literal table, because their atoms do not exist in the
  worker's VM; atoms come back here as `{:atom, name}` instead.

  The input is untrusted. Its size is capped (64 MiB, also after inflating a
  compressed term), every length and count is checked against the remaining
  input before anything is allocated, nesting is capped at 2,000 and the
  number of terms at 4,000,000. Anything malformed, truncated or unknown
  (including `LOCAL_EXT` and `ATOM_CACHE_REF`, which never appear in a beam)
  is `{:error, reason}`; nothing raises out of `decode/1`.

  Tree nodes: `{:atom, name}`, `{:int, n}` (small and 32-bit integers),
  `:bignum`, `:float`, `{:string, binary}` (`BINARY_EXT`, and `STRING_EXT`
  converted from Latin-1 to UTF-8), `{:bits, bytes}`, `{:list, items, tail}`
  (`{:list, [], nil}` is `[]`, so it is also a proper list's tail),
  `{:tuple, items}`, `{:map, [{key, value}]}`, `{:export, module, function,
  arity}`, `{:fun, module, free_variables}`, and `{:pid, node}`,
  `{:port, node}`, `{:ref, node}`.
  """

  @max_bytes 64 * 1024 * 1024
  @max_depth 2_000
  @max_nodes 4_000_000

  @type tree ::
          {:atom, binary()}
          | {:int, integer()}
          | :bignum
          | :float
          | {:string, binary()}
          | {:bits, binary()}
          | {:list, [tree()], tree() | nil}
          | {:tuple, [tree()]}
          | {:map, [{tree(), tree()}]}
          | {:export, tree(), tree(), non_neg_integer()}
          | {:fun, tree(), [tree()]}
          | {:pid | :port | :ref, tree()}

  @doc "Decodes one external term (`<<131, ...>>`), compressed or not."
  @spec decode(term()) :: {:ok, tree()} | {:error, String.t()}
  def decode(binary) when is_binary(binary) and byte_size(binary) > @max_bytes,
    do: {:error, "term larger than 64 MiB"}

  def decode(<<131, 80, size::32, compressed::binary>>) do
    with {:ok, inner} <- inflate(compressed, size), do: top(inner)
  end

  def decode(<<131, rest::binary>>), do: top(rest)
  def decode(_other), do: {:error, "not an external term"}

  @doc """
  Inflates a zlib stream that must come out at exactly `size` bytes, at most
  64 MiB. Output is checked chunk by chunk, so a bomb stops at the cap.
  """
  @spec inflate(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, String.t()}
  def inflate(_compressed, size) when size > @max_bytes, do: {:error, "inflates past 64 MiB"}

  def inflate(compressed, size) when is_binary(compressed) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflate_loop(z, :zlib.safeInflate(z, compressed), size, [], 0, 0)
    catch
      _kind, _reason -> {:error, "does not inflate"}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {:continue, out}, size, acc, total, empty) do
    total = total + IO.iodata_length(out)

    cond do
      total > size ->
        {:error, "inflates past its declared size"}

      empty > 2 ->
        {:error, "compressed data truncated"}

      true ->
        inflate_loop(
          z,
          :zlib.safeInflate(z, []),
          size,
          [acc | out],
          total,
          next_empty(out, empty)
        )
    end
  end

  defp inflate_loop(_z, {:finished, out}, size, acc, total, _empty) do
    if total + IO.iodata_length(out) == size,
      do: {:ok, IO.iodata_to_binary([acc | out])},
      else: {:error, "inflates to other than its declared size"}
  end

  defp inflate_loop(_z, _other, _size, _acc, _total, _empty), do: {:error, "does not inflate"}

  defp next_empty(out, empty), do: if(IO.iodata_length(out) == 0, do: empty + 1, else: 0)

  defp top(binary) do
    case term(binary, 0, 0) do
      {tree, <<>>, _n} -> {:ok, tree}
      {_tree, _trailing, _n} -> {:error, "trailing bytes"}
    end
  catch
    :throw, {:etf, why} -> {:error, why}
    # Defensive: every clause below is a match on the input, so nothing
    # should raise; if something does, the term is still not judged.
    _kind, _reason -> {:error, "malformed term"}
  end

  defp fail(why), do: throw({:etf, why})

  # Every term counts once against the node budget and goes one level deeper.
  defp term(_bin, depth, _n) when depth > @max_depth, do: fail("nested too deep")
  defp term(_bin, _depth, n) when n >= @max_nodes, do: fail("too many terms")
  defp term(bin, depth, n), do: tag(bin, depth, n + 1)

  # Numbers.
  defp tag(<<97, i, rest::binary>>, _d, n), do: {{:int, i}, rest, n}
  defp tag(<<98, i::signed-32, rest::binary>>, _d, n), do: {{:int, i}, rest, n}
  defp tag(<<70, _f::binary-size(8), rest::binary>>, _d, n), do: {:float, rest, n}
  defp tag(<<99, _f::binary-size(31), rest::binary>>, _d, n), do: {:float, rest, n}

  defp tag(<<110, len, sign, _digits::binary-size(len), rest::binary>>, _d, n)
       when sign in [0, 1],
       do: {:bignum, rest, n}

  defp tag(<<111, len::32, sign, _digits::binary-size(len), rest::binary>>, _d, n)
       when sign in [0, 1],
       do: {:bignum, rest, n}

  # Atoms: UTF-8 (118, 119) and Latin-1 (100, 115).
  defp tag(<<118, len::16, name::binary-size(len), rest::binary>>, _d, n),
    do: {utf8_atom(name), rest, n}

  defp tag(<<119, len, name::binary-size(len), rest::binary>>, _d, n),
    do: {utf8_atom(name), rest, n}

  defp tag(<<100, len::16, name::binary-size(len), rest::binary>>, _d, n) when len <= 255,
    do: {{:atom, latin1(name)}, rest, n}

  defp tag(<<115, len, name::binary-size(len), rest::binary>>, _d, n),
    do: {{:atom, latin1(name)}, rest, n}

  # Binaries and strings.
  defp tag(<<107, len::16, chars::binary-size(len), rest::binary>>, _d, n),
    do: {{:string, latin1(chars)}, rest, n}

  defp tag(<<109, len::32, bytes::binary-size(len), rest::binary>>, _d, n),
    do: {{:string, bytes}, rest, n}

  defp tag(<<77, len::32, bits, bytes::binary-size(len), rest::binary>>, _d, n)
       when len > 0 and bits in 1..8,
       do: {{:bits, bytes}, rest, n}

  # Containers.
  defp tag(<<104, arity, rest::binary>>, d, n), do: tuple(arity, rest, d, n)
  defp tag(<<105, arity::32, rest::binary>>, d, n), do: tuple(arity, rest, d, n)
  defp tag(<<106, rest::binary>>, _d, n), do: {{:list, [], nil}, rest, n}
  defp tag(<<108, len::32, rest::binary>>, d, n), do: list(len, rest, d, n)
  defp tag(<<116, arity::32, rest::binary>>, d, n), do: map(arity, rest, d, n)

  # Functions.
  defp tag(<<113, rest::binary>>, d, n), do: export(rest, d, n)

  defp tag(<<112, size::32, rest::binary>>, d, n)
       when size >= 4 and size - 4 <= byte_size(rest) do
    {body, rest} = :erlang.split_binary(rest, size - 4)
    {fun, n} = new_fun(body, d, n)
    {fun, rest, n}
  end

  # Pids, ports and references: a node atom and fixed-size fields.
  defp tag(<<103, rest::binary>>, d, n), do: node_then(:pid, rest, 9, d, n)
  defp tag(<<88, rest::binary>>, d, n), do: node_then(:pid, rest, 12, d, n)
  defp tag(<<102, rest::binary>>, d, n), do: node_then(:port, rest, 5, d, n)
  defp tag(<<89, rest::binary>>, d, n), do: node_then(:port, rest, 8, d, n)
  defp tag(<<120, rest::binary>>, d, n), do: node_then(:port, rest, 12, d, n)
  defp tag(<<101, rest::binary>>, d, n), do: node_then(:ref, rest, 5, d, n)

  defp tag(<<114, len::16, rest::binary>>, d, n) when len in 1..5,
    do: node_then(:ref, rest, 1 + 4 * len, d, n)

  defp tag(<<90, len::16, rest::binary>>, d, n) when len in 1..5,
    do: node_then(:ref, rest, 4 + 4 * len, d, n)

  defp tag(_bin, _d, _n), do: fail("unsupported or truncated term")

  defp tuple(arity, rest, _d, _n) when arity > byte_size(rest),
    do: fail("tuple larger than input")

  defp tuple(arity, rest, d, n) do
    {items, rest, n} = many(arity, rest, d + 1, n, [])
    {{:tuple, items}, rest, n}
  end

  # Every element takes at least one byte, and the tail at least one more.
  defp list(len, rest, _d, _n) when len >= byte_size(rest), do: fail("list larger than input")

  defp list(len, rest, d, n) do
    {items, rest, n} = many(len, rest, d + 1, n, [])
    {tail, rest, n} = term(rest, d + 1, n)
    {{:list, items, tail}, rest, n}
  end

  defp map(arity, rest, _d, _n) when arity * 2 > byte_size(rest),
    do: fail("map larger than input")

  defp map(arity, rest, d, n) do
    {items, rest, n} = many(arity * 2, rest, d + 1, n, [])
    {{:map, pairs(items, [])}, rest, n}
  end

  defp pairs([k, v | rest], acc), do: pairs(rest, [{k, v} | acc])
  defp pairs([], acc), do: Enum.reverse(acc)

  defp export(rest, d, n) do
    {module, rest, n} = term(rest, d + 1, n)
    {function, rest, n} = term(rest, d + 1, n)
    {arity, rest, n} = term(rest, d + 1, n)

    case {module, function, arity} do
      {{:atom, _}, {:atom, _}, {:int, a}} when a in 0..255 ->
        {{:export, module, function, a}, rest, n}

      _ ->
        fail("malformed export")
    end
  end

  # NEW_FUN_EXT: arity, uniq, index, free-variable count, then the module,
  # old index, old uniq and pid terms and the free variables; nothing after.
  defp new_fun(<<_arity, _uniq::binary-size(16), _index::32, free::32, rest::binary>>, d, n)
       when free <= byte_size(rest) do
    {module, rest, n} = term(rest, d + 1, n)
    {_old_index, rest, n} = term(rest, d + 1, n)
    {_old_uniq, rest, n} = term(rest, d + 1, n)
    {_pid, rest, n} = term(rest, d + 1, n)
    {vars, rest, n} = many(free, rest, d + 1, n, [])

    case {module, rest} do
      {{:atom, _}, <<>>} -> {{:fun, module, vars}, n}
      _ -> fail("malformed fun")
    end
  end

  defp new_fun(_body, _d, _n), do: fail("malformed fun")

  defp node_then(kind, rest, fixed, d, n) do
    case term(rest, d + 1, n) do
      {{:atom, _} = node, rest, n} when byte_size(rest) >= fixed ->
        {_fields, rest} = :erlang.split_binary(rest, fixed)
        {{kind, node}, rest, n}

      _ ->
        fail("malformed #{kind}")
    end
  end

  defp many(0, rest, _d, n, acc), do: {Enum.reverse(acc), rest, n}

  defp many(count, rest, d, n, acc) do
    {item, rest, n} = term(rest, d, n)
    many(count - 1, rest, d, n, [item | acc])
  end

  defp utf8_atom(name) do
    case :unicode.characters_to_list(name, :utf8) do
      chars when is_list(chars) and length(chars) <= 255 -> {:atom, name}
      _ -> fail("malformed atom")
    end
  end

  defp latin1(bytes), do: :unicode.characters_to_binary(bytes, :latin1)
end
