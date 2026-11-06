defmodule NccWorker.Portability.BuildRoot do
  @moduledoc """
  Spec R2: the build root may appear in a package's beams only as
  diagnostic metadata. Searches the literal table (`LitT`), the string table
  (`StrT`), the atom table (`AtU8`, or `Atom` in old beams) and the
  attribute chunk (`Attr`) of every beam in an `ebin`, and the `.app`, for
  the roots (project dir, OTP root, Elixir install, `HOME`, `MIX_HOME`,
  `HEX_HOME`).

  Each occurrence must be a string that is a closure file, inside
  `{:keep, {file, line}}`, a `file` key of a map or a `{:file, value}` pair
  (so keyword lists, `Macro.Env` and Erlang `?FILE` log metadata),
  `{module, {fun, arity}, file, line}`, or (in `Attr`) an
  `external_resource` entry: Elixir persists `@external_resource` paths
  there, and they act only on Mix's own recompilation of the dependency.
  Anything else refuses, including a root in an atom, a bitstring, a list of
  files (`__mix_recompile__?/0`), the string table, the atom table or the
  `.app`. `CInf`, `Dbgi`, `Docs` and `Line` are metadata and are not read.

  The beams are untrusted. They are read with a bounded IFF reader (no
  `:beam_lib`, which would gunzip a compressed beam without a bound) and
  their terms with `NccWorker.Portability.Etf`, which creates no atoms. A
  beam or `.app` this module cannot read is `{:error, reason}`, which the
  judge turns into "portability could not be judged": never a pass.
  """

  alias NccWorker.Portability.Etf

  @max_literal_bytes 64 * 1024 * 1024
  @max_file_bytes 256 * 1024 * 1024
  @chunks ~w(StrT AtU8 Atom LitT Attr)

  @spec check(String.t(), [String.t()], (String.t() -> boolean())) ::
          :ok | {:refuse, String.t()} | {:error, String.t()}
  def check(ebin, roots, closure_file?) do
    roots = needles(roots)

    with :ok <- each(files(ebin, "*.beam"), &check_beam(&1, roots, closure_file?)) do
      each(files(ebin, "*.app"), &check_app(&1, roots))
    end
  end

  defp each(paths, fun) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case fun.(path) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp files(ebin, pattern), do: ebin |> Path.join(pattern) |> Path.wildcard() |> Enum.sort()

  # Each root as given, plus its bytes read as Latin-1: a charlist of a
  # path's UTF-8 bytes (`:binary.bin_to_list/1`) decodes that way.
  defp needles(roots) do
    roots
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(&[&1, :unicode.characters_to_binary(&1, :latin1)])
    |> Enum.uniq()
  end

  defp check_beam(path, roots, closure_file?) do
    module = Path.basename(path, ".beam")

    with {:ok, binary} <- read(path, module),
         {:ok, chunks} <- chunks(binary, module),
         :ok <- search_bytes(chunks["StrT"], roots, module, "string table"),
         :ok <- search_bytes(chunks["AtU8"], roots, module, "atom table"),
         :ok <- search_bytes(chunks["Atom"], roots, module, "atom table"),
         :ok <- literals(chunks["LitT"], roots, closure_file?, module) do
      attributes(chunks["Attr"], roots, closure_file?, module)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path, name) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(path),
         {:ok, binary} <- File.read(path) do
      {:ok, binary}
    else
      _ -> {:error, "unreadable beam #{name}"}
    end
  end

  # The IFF container: "FOR1", the form size, "BEAM", then chunks of a
  # 4-byte id, a 32-bit size, the data and padding to 4 bytes. A chunk this
  # module reads may appear only once.
  defp chunks(<<"FOR1", size::32, "BEAM", body::binary>>, module)
       when size == byte_size(body) + 4,
       do: chunk_list(body, %{}, module)

  defp chunks(_binary, module), do: {:error, "unreadable beam #{module} (not a beam container)"}

  defp chunk_list(<<>>, acc, _module), do: {:ok, acc}

  defp chunk_list(
         <<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>,
         acc,
         module
       ) do
    pad = rem(4 - rem(len, 4), 4)

    cond do
      id in @chunks and Map.has_key?(acc, id) ->
        {:error, "unreadable beam #{module} (duplicate #{id})"}

      byte_size(rest) < pad and rest != <<>> ->
        {:error, "unreadable beam #{module} (truncated)"}

      true ->
        chunk_list(skip(rest, pad), keep(acc, id, data), module)
    end
  end

  defp chunk_list(_rest, _acc, module), do: {:error, "unreadable beam #{module} (truncated)"}

  defp skip(rest, pad) when byte_size(rest) < pad, do: <<>>
  defp skip(rest, pad), do: binary_part(rest, pad, byte_size(rest) - pad)

  defp keep(acc, id, data) when id in @chunks, do: Map.put(acc, id, data)
  defp keep(acc, _id, _data), do: acc

  defp search_bytes(data, roots, module, where) when is_binary(data) do
    case Enum.find(roots, &(:binary.match(data, &1) != :nomatch)) do
      nil -> :ok
      root -> {:refuse, "bakes the build path: #{module} #{where} #{inspect(root)}"}
    end
  end

  defp search_bytes(nil, _roots, _module, _where), do: :ok

  defp literals(nil, _roots, _closure_file?, _module), do: :ok

  # One entry at a time, so only one decoded literal is in memory.
  defp literals(chunk, roots, closure_file?, module) do
    result =
      fold_literal_table(chunk, :ok, fn tree, :ok ->
        case scan(tree, false, roots, closure_file?) do
          nil -> {:cont, :ok}
          offending -> {:halt, refusal(module, offending, roots)}
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _} = error -> error
    end
  end

  @doc """
  Decodes a `LitT` chunk into its literals, in order. The header is the
  inflated size (`0` for an uncompressed table, which OTP 28 writes); either
  size over 64 MiB is an error. Public for tests.
  """
  @spec literal_table(binary() | nil) :: {:ok, [Etf.tree()]} | {:error, String.t()}
  def literal_table(nil), do: {:ok, []}

  def literal_table(chunk) do
    with {:ok, trees} <- fold_literal_table(chunk, [], &{:cont, [&1 | &2]}),
         do: {:ok, Enum.reverse(trees)}
  end

  defp fold_literal_table(<<size::32, _rest::binary>>, _acc, _fun) when size > @max_literal_bytes,
    do: {:error, "literal table larger than 64 MiB"}

  defp fold_literal_table(<<0::32, table::binary>>, _acc, _fun)
       when byte_size(table) > @max_literal_bytes,
       do: {:error, "literal table larger than 64 MiB"}

  defp fold_literal_table(<<0::32, table::binary>>, acc, fun), do: entries(table, acc, fun)

  defp fold_literal_table(<<size::32, compressed::binary>>, acc, fun) do
    case Etf.inflate(compressed, size) do
      {:ok, table} -> entries(table, acc, fun)
      {:error, why} -> {:error, "literal table " <> why}
    end
  end

  defp fold_literal_table(_chunk, _acc, _fun), do: {:error, "literal table truncated"}

  # A count, then each literal as a 32-bit size and an external term.
  defp entries(<<count::32, rest::binary>>, acc, fun) when count * 4 <= byte_size(rest),
    do: entries(rest, count, acc, fun)

  defp entries(_table, _acc, _fun), do: {:error, "literal table truncated"}

  defp entries(<<>>, 0, acc, _fun), do: {:ok, acc}

  defp entries(<<len::32, term::binary-size(len), rest::binary>>, n, acc, fun) when n > 0 do
    with {:ok, tree} <- literal(term),
         {:cont, acc} <- fun.(tree, acc) do
      entries(rest, n - 1, acc, fun)
    else
      {:halt, acc} -> {:ok, acc}
      {:error, _} = error -> error
    end
  end

  defp entries(_rest, _n, _acc, _fun), do: {:error, "literal table truncated"}

  defp literal(term) do
    case Etf.decode(term) do
      {:ok, tree} -> {:ok, tree}
      {:error, why} -> {:error, "literal table: " <> why}
    end
  end

  defp attributes(nil, _roots, _closure_file?, _module), do: :ok

  defp attributes(chunk, roots, closure_file?, module) do
    case Etf.decode(chunk) do
      {:ok, tree} ->
        case scan(tree, false, roots, closure_file?) do
          nil -> :ok
          offending -> refusal(module, offending, roots)
        end

      {:error, why} ->
        {:error, "attributes of #{module}: " <> why}
    end
  end

  defp refusal(module, offending, roots),
    do: {:refuse, "bakes the build path: #{module} #{snippet(offending, roots)}"}

  # Returns the first offending string, or nil. `allowed?` says the node sits
  # in an allowed shape, where a closure file is fine.
  defp scan({:string, s}, allowed?, roots, ok?) do
    if contains_root?(s, roots) and not (allowed? and ok?.(s)), do: s
  end

  defp scan({:atom, name}, _allowed?, roots, _ok?), do: if(contains_root?(name, roots), do: name)

  defp scan({:bits, bytes}, _allowed?, roots, _ok?),
    do: if(contains_root?(bytes, roots), do: bytes)

  defp scan({:list, items, tail} = node, allowed?, roots, ok?) do
    case charlist(node) do
      nil -> any([tail | items], roots, ok?)
      string -> scan({:string, string}, allowed?, roots, ok?)
    end
  end

  defp scan({:tuple, [{:atom, "keep"}, {:tuple, [file, {:int, _}]}]}, _a, roots, ok?),
    do: scan(file, true, roots, ok?)

  defp scan({:tuple, [{:atom, "file"}, file]}, _a, roots, ok?), do: scan(file, true, roots, ok?)

  defp scan(
         {:tuple, [{:atom, _} = m, {:tuple, [{:atom, _} = f, {:int, _}]}, file, {:int, _}]},
         _a,
         roots,
         ok?
       ),
       do: any([m, f], roots, ok?) || scan(file, true, roots, ok?)

  defp scan({:tuple, [{:atom, "external_resource"}, {:list, files, tail}]}, _a, roots, ok?),
    do: scan(tail, false, roots, ok?) || Enum.find_value(files, &scan(&1, true, roots, ok?))

  defp scan({:tuple, items}, _a, roots, ok?), do: any(items, roots, ok?)

  defp scan({:map, pairs}, _a, roots, ok?) do
    Enum.find_value(pairs, fn {key, value} ->
      scan(key, false, roots, ok?) || scan(value, key == {:atom, "file"}, roots, ok?)
    end)
  end

  defp scan({:export, m, f, _arity}, _a, roots, ok?), do: any([m, f], roots, ok?)
  defp scan({:fun, m, vars}, _a, roots, ok?), do: any([m | vars], roots, ok?)

  defp scan({kind, node}, _a, roots, ok?) when kind in [:pid, :port, :ref],
    do: scan(node, false, roots, ok?)

  defp scan(_other, _allowed?, _roots, _ok?), do: nil

  defp any(nodes, roots, ok?), do: Enum.find_value(nodes, &scan(&1, false, roots, ok?))

  # A proper, non-empty list of code points is a charlist (an Erlang string
  # whose code points do not all fit `STRING_EXT`).
  defp charlist({:list, [_ | _] = items, {:list, [], nil}}) do
    if Enum.all?(items, &codepoint?/1) do
      items |> Enum.map(fn {:int, c} -> c end) |> List.to_string()
    end
  end

  defp charlist(_node), do: nil

  defp codepoint?({:int, c}), do: c in 0..0xD7FF or c in 0xE000..0x10FFFF
  defp codepoint?(_node), do: false

  defp contains_root?(s, roots), do: Enum.any?(roots, &(:binary.match(s, &1) != :nomatch))

  # The offending string with each root shown as `<root>`, so the reason
  # names what was baked rather than where this run happened to build.
  defp snippet(s, roots) do
    s
    |> :binary.replace(roots, "<root>", [:global])
    |> inspect(printable_limit: 120)
    |> String.slice(0, 160)
  end

  # The .app has no allowed shape: any root in it refuses.
  defp check_app(path, roots) do
    name = Path.basename(path)

    case read(path, name) do
      {:ok, binary} -> search_bytes(binary, roots, name, "application file")
      {:error, _} -> {:error, "unreadable application file #{name}"}
    end
  end
end
