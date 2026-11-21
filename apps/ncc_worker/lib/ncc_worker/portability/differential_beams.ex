defmodule NccWorker.Portability.DifferentialBeams do
  @moduledoc """
  The comparison of a differential build (`NccWorker.Portability.Differential`):
  whether the app a package's first build wrote is the app a variant build
  wrote, the variant having compiled the same closure with a host value
  changed and at a build root of its own.

  The standard is the zero-false-hit check's (`:beam_lib.strip/1` and the
  residue a build root leaves), stricter where a running program can see
  the difference:

    * the same `ebin` file names, every file that is not a beam the same
      bytes, and the same `priv` tree: the same relative paths, types,
      permission bits and bytes, a link the same target;
    * every beam the same chunk ids, and every chunk the same bytes but for
      `CInf`, `Dbgi` and `ExCk`: compile metadata, debug info and the type
      checker's signatures, which `strip/1` drops too and whose order a
      compile's own async streams shuffle (a spec union, the definitions'
      order). `Docs` and `Attr` are compared, which `strip/1` does not:
      `Code.fetch_docs/1` and `module_info(:attributes)` read them at
      runtime;
    * `LitT` (and a compressed `Docs`) inflated first, under a bound;
      `FunT` may differ in each fun's `old_uniq` alone and `Attr` in the
      `vsn` md5 alone, both derived from the module's md5, which a build
      root in the literals changes.

  `roots` is `{first, variant}`, the two build roots. When they have the
  same byte length every occurrence of the variant's in the variant's bytes
  is read as the first's (every length field stays right), so a build root
  in a literal or a line table is no difference; R2 judges those already
  (`NccWorker.Portability.BuildRoot`). Otherwise nothing is substituted and
  the bytes must be the same.

  The beams are untrusted (package code wrote them): no `:beam_lib`, no
  atom is created and every inflation is bounded. Never raises: a file
  that cannot be read is `{:error, why}`, never a match.
  """

  alias NccWorker.Portability.Etf

  @skipped ~w(CInf Dbgi ExCk)
  # `{vsn, [_]}`'s tuple head is followed by one of these atom encodings,
  # then a one-element list.
  @vsn_atoms [<<119, 3, "vsn">>, <<115, 3, "vsn">>, <<118, 0, 3, "vsn">>, <<100, 0, 3, "vsn">>]
  @one <<108, 0, 0, 0, 1>>
  @max_file_bytes 64 * 1024 * 1024
  @max_entries 20_000

  @type result :: :ok | {:differs, String.t()} | {:error, String.t()}

  @doc "Compares the first build's app dir with a variant's (see the moduledoc)."
  @spec compare_app(String.t(), String.t(), {String.t(), String.t()} | nil) :: result()
  def compare_app(first, variant, roots) do
    sub = substitution(roots)

    with :ok <- compare_ebin(Path.join(first, "ebin"), Path.join(variant, "ebin"), sub) do
      compare_tree(Path.join(first, "priv"), Path.join(variant, "priv"), "priv", sub)
    end
  rescue
    e -> {:error, "comparison failed: " <> Exception.message(e)}
  end

  defp substitution({first, variant})
       when is_binary(first) and is_binary(variant) and first != variant and
              byte_size(first) == byte_size(variant) and byte_size(first) > 1,
       do: {variant, first}

  defp substitution(_roots), do: nil

  # sobelow_skip ["Traversal.FileModule"]
  defp compare_ebin(a, b, sub) do
    with {:ok, names_a} <- list(a),
         {:ok, names_b} <- list(b) do
      cond do
        names_a == [] -> {:error, "no ebin files"}
        names_a != names_b -> {:differs, "ebin holds other files"}
        true -> Enum.reduce_while(names_a, :ok, &ebin_file(&1, &2, a, b, sub))
      end
    end
  end

  defp ebin_file(name, :ok, a, b, sub) do
    with {:ok, x} <- read(Path.join(a, name)),
         {:ok, y} <- read(Path.join(b, name)) do
      result =
        cond do
          x == y -> :ok
          Path.extname(name) == ".beam" -> compare_beam(x, y, sub)
          substitute(y, sub) == x -> :ok
          true -> {:differs, "differs"}
        end

      case result do
        :ok -> {:cont, :ok}
        {kind, why} -> {:halt, {kind, "ebin/#{name}: #{why}"}}
      end
    else
      {:error, why} -> {:halt, {:error, "ebin/#{name}: #{why}"}}
    end
  end

  @doc """
  Compares one beam of the first build with the variant's (see the
  moduledoc); `sub` is `{variant_root, first_root}` or nil.
  """
  @spec compare_beam(binary(), binary(), {binary(), binary()} | nil) :: result()
  def compare_beam(x, y, sub) do
    with {:ok, a} <- chunks(x),
         {:ok, b} <- chunks(y) do
      if Enum.sort(ids(a)) == Enum.sort(ids(b)),
        do: compare_chunks(a, b, sub),
        else: {:differs, "other chunks"}
    end
  end

  defp ids(chunks), do: Enum.map(chunks, &elem(&1, 0))

  defp compare_chunks(a, b, sub) do
    differ =
      for {id, bytes} <- a,
          id not in @skipped,
          {_, other} = List.keyfind(b, id, 0),
          not same_chunk?(id, bytes, other, sub),
          do: id

    case differ do
      [] -> :ok
      ids -> {:differs, Enum.join(ids, ", ")}
    end
  end

  # Chunk ids stay the binaries they are: no atom is made of them.
  defp same_chunk?(_id, same, same, _sub), do: true
  defp same_chunk?("LitT", a, b, sub), do: same_inflated(literals(a), literals(b), sub)
  defp same_chunk?("Docs", a, b, sub), do: same_inflated(term_bytes(a), term_bytes(b), sub)

  defp same_chunk?("FunT", a, b, sub) do
    b = substitute(b, sub)

    a == b or
      case {funs_but_uniq(a), funs_but_uniq(b)} do
        {{:ok, x}, {:ok, x}} -> true
        _ -> false
      end
  end

  defp same_chunk?("Attr", a, b, sub) do
    b = substitute(b, sub)
    a == b or without_vsn(a) == without_vsn(b)
  end

  defp same_chunk?(_id, a, b, sub), do: substitute(b, sub) == a

  # Two chunks that inflated (each under its declared size) to the same
  # bytes; one that does not inflate is never the same.
  defp same_inflated({:ok, x}, {:ok, y}, sub), do: substitute(y, sub) == x
  defp same_inflated(_a, _b, _sub), do: false

  defp substitute(bytes, nil), do: bytes
  defp substitute(bytes, {from, to}), do: :binary.replace(bytes, from, to, [:global])

  # `LitT`: the uncompressed size, then the zlib-compressed table; a size of
  # 0 is a table stored as it is.
  defp literals(<<0::32, raw::binary>>), do: {:ok, raw}
  defp literals(<<size::32, compressed::binary>>), do: Etf.inflate(compressed, size)
  defp literals(_bytes), do: :error

  defp term_bytes(<<131, 80, size::32, compressed::binary>>), do: Etf.inflate(compressed, size)
  defp term_bytes(bytes), do: {:ok, bytes}

  # The fun table without each entry's last word, `old_uniq`: the same funs
  # at the same labels, indices and free-variable counts.
  defp funs_but_uniq(<<count::32, table::binary>>) when byte_size(table) == count * 24,
    do: {:ok, for(<<keep::binary-size(20), _uniq::32 <- table>>, do: keep)}

  defp funs_but_uniq(_bytes), do: :error

  # The `vsn` md5 zeroed wherever `{vsn, [Integer]}` is encoded, whatever
  # the atom's encoding.
  defp without_vsn(bytes) do
    Enum.reduce(@vsn_atoms, bytes, fn atom, acc -> zero_vsn(acc, <<104, 2>> <> atom <> @one) end)
  end

  defp zero_vsn(bytes, prefix) do
    case :binary.split(bytes, prefix) do
      [head, rest] -> head <> prefix <> zero_int(rest)
      [_] -> bytes
    end
  end

  defp zero_int(<<110, len, sign, _digits::binary-size(len), 106, rest::binary>>),
    do: <<110, len, sign, 0::size(len)-unit(8), 106>> <> rest

  defp zero_int(<<98, _::32, 106, rest::binary>>), do: <<98, 0::32, 106>> <> rest
  defp zero_int(<<97, _, 106, rest::binary>>), do: <<97, 0, 106>> <> rest
  defp zero_int(rest), do: rest

  # The beam's chunks as `[{id, bytes}]`, from an uncompressed (or gzipped,
  # inflated under the cap) `FOR1 ... BEAM` file whose chunks fill it
  # exactly, each id once.
  defp chunks(<<31, 139, _::binary>> = gz) do
    case Etf.gunzip(gz, @max_file_bytes) do
      {:ok, beam} -> chunks(beam)
      {:error, _why} -> {:error, "unreadable beam"}
    end
  end

  defp chunks(<<"FOR1", size::32, "BEAM", rest::binary>>)
       when size >= 4 and size - 4 <= byte_size(rest) do
    with {:ok, chunks} <- read_chunks(binary_part(rest, 0, size - 4), []),
         true <- ids(chunks) == Enum.uniq(ids(chunks)) do
      {:ok, chunks}
    else
      _ -> {:error, "unreadable beam"}
    end
  end

  defp chunks(_bytes), do: {:error, "unreadable beam"}

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    case rest do
      <<_pad::binary-size(^pad), rest::binary>> -> read_chunks(rest, [{id, data} | acc])
      <<>> -> read_chunks(<<>>, [{id, data} | acc])
      _ -> :error
    end
  end

  defp read_chunks(_bytes, _acc), do: :error

  # A dir's entry names, sorted; a missing dir is an error.
  # sobelow_skip ["Traversal.FileModule"]
  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} when length(names) <= @max_entries -> {:ok, Enum.sort(names)}
      {:ok, _names} -> {:error, "over #{@max_entries} entries"}
      {:error, why} -> {:error, "#{Path.basename(dir)}: #{inspect(why)}"}
    end
  end

  # A regular file's bytes, under the cap, read without following a link.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, why} -> {:error, inspect(why)}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "over #{@max_file_bytes} bytes"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "a #{type}"}

      {:error, why} ->
        {:error, inspect(why)}
    end
  end

  # The two `priv` entries at `rel`: both missing, the same link target,
  # the same regular file (permission bits and bytes), or two directories
  # whose entries compare the same.
  # sobelow_skip ["Traversal.FileModule"]
  defp compare_tree(a, b, rel, sub) do
    case {File.lstat(a), File.lstat(b)} do
      {{:error, :enoent}, {:error, :enoent}} ->
        :ok

      {{:ok, %File.Stat{type: :symlink}}, {:ok, %File.Stat{type: :symlink}}} ->
        same_link(a, b, rel, sub)

      {{:ok, %File.Stat{type: :regular} = sa}, {:ok, %File.Stat{type: :regular} = sb}} ->
        same_file(a, b, sa, sb, rel, sub)

      {{:ok, %File.Stat{type: :directory} = sa}, {:ok, %File.Stat{type: :directory} = sb}} ->
        same_dir(a, b, sa, sb, rel, sub)

      {{:ok, _}, {:ok, _}} ->
        {:differs, "#{rel}: another type"}

      {{:error, :enoent}, _} ->
        {:differs, "#{rel}: only in the variant"}

      {_, {:error, :enoent}} ->
        {:differs, "#{rel}: only in the first build"}

      _ ->
        {:error, "#{rel}: unreadable"}
    end
  end

  # A link names the same target when both resolve, from their own dirs, to
  # the same path: Mix links a build's `priv` to the dependency's sources by
  # a relative path, whose `..` count follows the build root's depth.
  # sobelow_skip ["Traversal.FileModule"]
  defp same_link(a, b, rel, sub) do
    case {File.read_link(a), File.read_link(b)} do
      {{:ok, t}, {:ok, u}} ->
        if substitute(target(b, u), sub) == target(a, t),
          do: :ok,
          else: {:differs, "#{rel}: another link target"}

      _ ->
        {:error, "#{rel}: unreadable link"}
    end
  end

  defp target(link, target), do: Path.expand(target, Path.dirname(link))

  defp same_file(a, b, sa, sb, rel, sub) do
    with :ok <- same_mode(sa, sb, rel),
         {:ok, x} <- read(a),
         {:ok, y} <- read(b) do
      if x == y or substitute(y, sub) == x, do: :ok, else: {:differs, "#{rel}: differs"}
    else
      {:error, why} -> {:error, "#{rel}: #{why}"}
      other -> other
    end
  end

  defp same_dir(a, b, sa, sb, rel, sub) do
    with :ok <- same_mode(sa, sb, rel),
         {:ok, names_a} <- list(a),
         {:ok, names_b} <- list(b) do
      if names_a == names_b,
        do: Enum.reduce_while(names_a, :ok, &same_entry(&1, &2, a, b, rel, sub)),
        else: {:differs, "#{rel}: other entries"}
    end
  end

  defp same_entry(name, :ok, a, b, rel, sub) do
    case compare_tree(Path.join(a, name), Path.join(b, name), rel <> "/" <> name, sub) do
      :ok -> {:cont, :ok}
      other -> {:halt, other}
    end
  end

  defp same_mode(%File.Stat{mode: x}, %File.Stat{mode: y}, rel) do
    if Bitwise.band(x, 0o7777) == Bitwise.band(y, 0o7777),
      do: :ok,
      else: {:differs, "#{rel}: other permissions"}
  end
end
