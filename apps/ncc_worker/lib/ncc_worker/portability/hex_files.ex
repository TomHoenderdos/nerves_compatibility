defmodule NccWorker.Portability.HexFiles do
  @moduledoc """
  The file list a Hex release declares, read from the `metadata.config`
  inside its tarball (`NccWorker.Portability.Context`'s source of "in the
  tarball", spec R1 "Files").

  Only the tarball the lock's outer checksum verified is read
  (`NccWorker.HexCache.package_tarball/4`), never `deps/<d>/hex_metadata.config`:
  an untraced native build step can rewrite that file, the tarball it cannot.

  `metadata.config` is anyone's text, so it is read by a parser of its own
  rather than `:file.consult/1`: it is bounded (1 MiB, nesting 64 deep), it
  never creates an atom (an atom comes back as `{:atom, name}`), and anything
  it does not understand is an error, never a raise. It reads the subset Hex
  writes: binaries (with `/utf8`), strings, lists, tuples, maps, atoms and
  numbers, `%` comments, each term ended by a `.`.

  Each entry is returned as its path segments, `.` segments dropped. An
  absolute or empty entry, or one with a `..` segment, is dropped, never
  widened to its parent.
  """

  @max_bytes 1024 * 1024
  @max_depth 64

  @type entry :: [String.t()]

  @doc "The release's declared files, or `nil` when the tarball or its list is unreadable."
  @spec from_tarball(binary() | nil) :: [entry()] | nil
  def from_tarball(bytes) when is_binary(bytes) do
    case :erl_tar.extract({:binary, bytes}, [:memory, {:files, [~c"metadata.config"]}]) do
      {:ok, [{_name, meta}]} when byte_size(meta) <= @max_bytes -> files(meta)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def from_tarball(_bytes), do: nil

  defp files(meta) do
    with {:ok, terms} <- parse(meta),
         {_key, list} when is_list(list) <- List.keyfind(terms, "files", 0) do
      for file <- list, is_binary(file), parts = entry(file), parts != nil, do: parts
    else
      _ -> nil
    end
  end

  defp entry(file) do
    parts = file |> Path.split() |> Enum.reject(&(&1 == "."))

    cond do
      parts == [] -> nil
      Path.type(file) != :relative -> nil
      ".." in parts -> nil
      true -> parts
    end
  end

  @doc "The terms of a `file:consult/1`-style text, without creating atoms."
  @spec parse(binary()) :: {:ok, [term()]} | :error
  def parse(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    terms(skip(text), [])
  rescue
    _ -> :error
  catch
    :parse_error -> :error
  end

  def parse(_text), do: :error

  defp terms("", acc), do: {:ok, Enum.reverse(acc)}

  defp terms(text, acc) do
    {term, rest} = term(text, 0)

    case skip(rest) do
      "." <> rest -> terms(skip(rest), [term | acc])
      _ -> fail()
    end
  end

  defp fail, do: throw(:parse_error)

  # Whitespace and `%` comments.
  defp skip(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip(rest)
  defp skip("%" <> rest), do: rest |> skip_line() |> skip()
  defp skip(text), do: text

  defp skip_line(""), do: ""
  defp skip_line("\n" <> rest), do: rest
  defp skip_line(<<_c, rest::binary>>), do: skip_line(rest)

  defp term(_text, depth) when depth > @max_depth, do: fail()
  defp term("<<" <> rest, _depth), do: binary(skip(rest))
  defp term("[" <> rest, depth), do: seq(skip(rest), "]", depth + 1, [])
  defp term("{" <> rest, depth), do: tuple(seq(skip(rest), "}", depth + 1, []))
  defp term("\#{" <> rest, depth), do: map(seq(skip(rest), "}", depth + 1, []))
  defp term("\"" <> rest, _depth), do: quoted(rest, ?", [])
  defp term("'" <> rest, _depth), do: atom(quoted(rest, ?', []))
  defp term(<<c, _::binary>> = text, _depth) when c in ?a..?z, do: bare_atom(text)
  defp term(<<c, _::binary>> = text, _depth) when c in ?0..?9 or c == ?-, do: number(text)
  defp term(_text, _depth), do: fail()

  defp tuple({items, rest}), do: {List.to_tuple(items), rest}
  defp atom({chars, rest}), do: {{:atom, List.to_string(chars)}, rest}

  defp map({items, rest}) do
    pairs = for {:"=>", k, v} <- items, do: {k, v}
    if length(pairs) == length(items), do: {Map.new(pairs), rest}, else: fail()
  end

  # Comma-separated terms up to `close`; inside a map each is `key => value`.
  defp seq(<<c, rest::binary>>, <<c>>, _depth, []), do: {[], rest}

  defp seq(text, close, depth, acc) do
    {item, rest} = item(text, close, depth)

    case skip(rest) do
      "," <> rest -> seq(skip(rest), close, depth, [item | acc])
      <<c, rest::binary>> when <<c>> == close -> {Enum.reverse([item | acc]), rest}
      _ -> fail()
    end
  end

  defp item(text, close, depth) do
    {term, rest} = term(text, depth)

    case {close, skip(rest)} do
      {"}", "=>" <> rest} -> map_value(term, skip(rest), depth)
      {_close, rest} -> {term, rest}
    end
  end

  defp map_value(key, text, depth) do
    {value, rest} = term(text, depth)
    {{:"=>", key, value}, rest}
  end

  # `<<>>`, `<<"text">>`, `<<"text"/utf8>>` or `<<1,2,3>>`.
  defp binary(">>" <> rest), do: {"", rest}
  defp binary(text), do: segments(text, [])

  defp segments(text, acc) do
    {bytes, rest} = segment(text)

    case skip(rest) do
      "," <> rest -> segments(skip(rest), [bytes | acc])
      ">>" <> rest -> {IO.iodata_to_binary(Enum.reverse([bytes | acc])), rest}
      _ -> fail()
    end
  end

  defp segment("\"" <> rest) do
    {chars, rest} = quoted(rest, ?", [])

    case skip(rest) do
      "/utf8" <> rest -> {utf8(chars), rest}
      rest -> {latin1(chars), rest}
    end
  end

  defp segment(text) do
    case number(text) do
      {n, rest} when is_integer(n) and n in 0..255 -> {<<n>>, rest}
      _ -> fail()
    end
  end

  defp utf8(chars) do
    case :unicode.characters_to_binary(chars) do
      bin when is_binary(bin) -> bin
      _ -> fail()
    end
  end

  defp latin1(chars) do
    if Enum.all?(chars, &(&1 in 0..255)), do: :erlang.list_to_binary(chars), else: fail()
  end

  # The characters of a quoted string or atom up to its closing `quote`.
  defp quoted(<<q, rest::binary>>, q, acc), do: {Enum.reverse(acc), rest}
  defp quoted("\\" <> rest, q, acc), do: escape(rest, q, acc)
  defp quoted(<<c::utf8, rest::binary>>, q, acc), do: quoted(rest, q, [c | acc])
  defp quoted(<<c, rest::binary>>, q, acc), do: quoted(rest, q, [c | acc])
  defp quoted("", _q, _acc), do: fail()

  @escapes %{
    ?n => ?\n,
    ?t => ?\t,
    ?r => ?\r,
    ?s => ?\s,
    ?b => ?\b,
    ?f => ?\f,
    ?v => ?\v,
    ?e => 27,
    ?d => 127,
    ?\\ => ?\\,
    ?" => ?",
    ?' => ?'
  }

  defp escape("x{" <> rest, q, acc) do
    case Integer.parse(rest, 16) do
      {n, "}" <> rest} when n in 0..0x10FFFF -> quoted(rest, q, [n | acc])
      _ -> fail()
    end
  end

  defp escape(<<"x", h1, h2, rest::binary>>, q, acc) do
    case Integer.parse(<<h1, h2>>, 16) do
      {n, ""} -> quoted(rest, q, [n | acc])
      _ -> fail()
    end
  end

  defp escape(<<c, _::binary>> = text, q, acc) when c in ?0..?7 do
    {digits, rest} = octal(text, [])
    quoted(rest, q, [List.to_integer(digits, 8) | acc])
  end

  defp escape(<<c, rest::binary>>, q, acc) when is_map_key(@escapes, c),
    do: quoted(rest, q, [Map.fetch!(@escapes, c) | acc])

  defp escape(_text, _q, _acc), do: fail()

  defp octal(<<c, rest::binary>>, acc) when c in ?0..?7 and length(acc) < 3,
    do: octal(rest, [c | acc])

  defp octal(rest, acc), do: {Enum.reverse(acc), rest}

  defp bare_atom(text) do
    [name] = Regex.run(~r/\A[a-z][A-Za-z0-9_@]*/, text)
    {{:atom, name}, binary_part(text, byte_size(name), byte_size(text) - byte_size(name))}
  end

  defp number(text) do
    case Regex.run(~r/\A-?[0-9]+(\.[0-9]+([eE][-+]?[0-9]+)?)?/, text) do
      [num | _] ->
        {to_number(num), binary_part(text, byte_size(num), byte_size(text) - byte_size(num))}

      nil ->
        fail()
    end
  end

  defp to_number(num) do
    if String.contains?(num, "."), do: String.to_float(num), else: String.to_integer(num)
  end
end
