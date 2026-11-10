defmodule NccWorker.NervesCode do
  @moduledoc """
  Rule 2's Nerves check (precompiled judge refinements spec, item 2): a
  package is "nerves-specific source" when its code names Nerves, not when
  its prose does. A heuristic for the hit rate, not a safety rule: builds
  run with `MIX_TARGET=host`, and per-target behaviour enters through
  `Mix.target`/`MIX_TARGET` (`BuildCache`'s target grep and the trace) or
  config (R5), which stay as they are.

  Files: `.ex`, `.exs` and `.erl` under the package, never under its
  top-level `priv/` (not compiled: Phoenix's EEx generator templates live
  there), never through a symlink (grep -r does not follow one either).

    * Elixir: parsed by `Code.string_to_quoted/2` with every static atom
      encoded as a tuple of the marker and its text, so no atom is created,
      in a spawned process with a heap cap and a 5 s timeout. A mention is
      an alias segment starting with `Nerves`, or any other atom or
      identifier containing `nerves` (any case), or a literal part of an
      interpolated atom (`:"Elixir.Nerves.\#{x}"`) containing it;
      interpolation is code.
    * Erlang: a hand-written linear lexer (`erl_scan` creates atoms) blanks
      comments, strings and character literals; any remaining text with
      `nerves` (any case) counts, quoted atoms included. It does not model
      OTP 27's sigils or triple-quoted strings, so a file with a `~` in code
      or a `\"""` anywhere, or an unterminated string or atom, keeps the
      raw verdict. It runs under the same heap cap and timeout.

  In both languages a string, charlist or `~w` word whose whole content is
  a module or app name (`Elixir.Nerves.Runtime`, `Nerves`, `nerves_runtime`)
  counts, and so does a prefix of one (`"Elixir.Nerves."`, `"nerves_"`) or
  an interpolated string that starts with one: it is how code builds that
  name (`String.to_atom/1`, `Module.concat/1`). Other string, charlist and sigil contents and comments
  are prose and do not count. A name built by concatenation (`"Ner" <>
  "ves"`) is seen by neither this nor the old grep.

  Monotone: a file counts only when today's raw case-insensitive search
  (`BuildSelection`'s grep) finds `nerves` in it too, and a file over 2 MB,
  one that does not parse, one whose parse is killed or times out, and every
  file left once `mention/2`'s time budget (60 s) is spent uses that raw
  search. So this never refuses what rule 2 accepted before.
  """

  @max_file_bytes 2 * 1024 * 1024
  @parse_timeout_ms 5_000
  # About 256 MiB of heap on a 64-bit VM.
  @parse_max_heap_words 32 * 1024 * 1024
  @scan_budget_ms 60_000
  @marker :__ncc_nerves_code_atom__
  @erlang_special ["%", "\"", "'", "$", "~"]
  @extensions ~w(.ex .exs .erl)

  @doc """
  Whether the sources under `dir` name Nerves in code. `budget_ms:` (60 s)
  bounds the whole scan: files left once it is spent use the raw search.
  """
  @spec mention(String.t(), keyword()) :: :found | :none | :missing | :error
  def mention(dir, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :budget_ms, @scan_budget_ms)
    if File.dir?(dir), do: scan(dir, deadline), else: :missing
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp scan(dir, deadline) do
    case files(dir, dir) do
      {:ok, files} ->
        if Enum.any?(files, &file_mention?(&1, deadline)), do: :found, else: :none

      :error ->
        :error
    end
  catch
    :unreadable -> :error
  end

  # Regular files only, `lstat`, so a symlink is neither followed nor read.
  # sobelow_skip ["Traversal.FileModule"]
  defp files(root, dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, &collect(root, Path.join(dir, &1), &2))

      {:error, _reason} ->
        :error
    end
  end

  defp collect(root, path, {:ok, acc}) do
    case entry(root, path) do
      {:ok, found} -> {:cont, {:ok, found ++ acc}}
      :error -> {:halt, :error}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp entry(root, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if path == Path.join(root, "priv"), do: {:ok, []}, else: files(root, path)

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, if(Path.extname(path) in @extensions, do: [{path, size}], else: [])}

      {:ok, _other} ->
        {:ok, []}

      {:error, _reason} ->
        :error
    end
  end

  # A file over the cap is never read whole: the raw search streams it.
  defp file_mention?({path, size}, _deadline) when size > @max_file_bytes,
    do: stream_raw?(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp file_mention?({path, _size}, deadline) do
    case File.read(path) do
      {:ok, source} -> raw?(source) and (now_ms() >= deadline or code_mention?(path, source))
      {:error, _reason} -> throw(:unreadable)
    end
  end

  # The raw search over 64 KiB chunks, keeping the last five bytes so a
  # match across a chunk boundary is still found.
  # sobelow_skip ["Traversal.FileModule"]
  defp stream_raw?(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce_while("", fn chunk, tail ->
      buffer = tail <> chunk

      if raw?(buffer),
        do: {:halt, true},
        else: {:cont, binary_part(buffer, byte_size(buffer), -min(5, byte_size(buffer)))}
    end)
    |> Kernel.==(true)
  rescue
    _ -> throw(:unreadable)
  end

  defp raw?(source), do: Regex.match?(~r/nerves/i, source)

  # A string's whole content is a module or app name that names Nerves, or
  # the prefix of one (`"Elixir.Nerves." <> x`, `"nerves_" ++ X`).
  defp name_literal?(text) when is_binary(text) do
    Regex.match?(~r/\A(Elixir\.)?Nerves(\.[A-Z]\w*)*\.?\z/, text) or
      Regex.match?(~r/\Anerves(_\w*)?\z/i, text)
  end

  defp code_mention?(_path, source) when byte_size(source) > @max_file_bytes, do: true

  defp code_mention?(path, source) do
    if Path.extname(path) == ".erl",
      do: erlang_mention?(source),
      else: elixir_mention?(source)
  end

  @doc "Whether Elixir `source` names Nerves in code (see the moduledoc)."
  @spec elixir_mention?(binary()) :: boolean()
  def elixir_mention?(source) when is_binary(source) do
    case bounded(fn -> parse_mention(source) end) do
      {:ok, found} -> found and raw?(source)
      :fallback -> raw?(source)
    end
  end

  # Not valid UTF-8: the tokenizer would raise, so go straight to the raw
  # search rather than crash (and log) the parse process.
  defp parse_mention(source) do
    if String.valid?(source), do: quoted_mention(source), else: :fallback
  end

  defp quoted_mention(source) do
    encoder = fn token, _meta -> {:ok, {@marker, token}} end

    case Code.string_to_quoted(strip_bom(source),
           existing_atoms_only: false,
           static_atoms_encoder: encoder,
           emit_warnings: false
         ) do
      {:ok, ast} -> {:ok, ast_mention?(ast)}
      {:error, _reason} -> :fallback
    end
  end

  # A leading UTF-8 byte order mark is not Elixir syntax; the raw search
  # still sees the whole file.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(source), do: source

  defp ast_mention?({:__aliases__, _meta, segments}) when is_list(segments) do
    Enum.any?(segments, fn
      {@marker, segment} when is_binary(segment) -> String.starts_with?(segment, "Nerves")
      other -> ast_mention?(other)
    end)
  end

  defp ast_mention?({@marker, token}) when is_binary(token), do: contains?(token)

  # An interpolated atom (`:"a#{x}"`, `"a#{x}": 1`): the parser's own form,
  # whose atoms are not encoded. Its literal parts are part of an atom.
  defp ast_mention?({{:., _, [:erlang, :binary_to_atom]}, _, [{:<<>>, _, parts}, :utf8]})
       when is_list(parts) do
    Enum.any?(parts, fn
      part when is_binary(part) -> contains?(part)
      other -> ast_mention?(other)
    end)
  end

  # `~w(...)`: each word is a string, charlist or atom of its own.
  defp ast_mention?({sigil, _, [{:<<>>, _, parts}, _modifiers]})
       when sigil in [:sigil_w, :sigil_W] and is_list(parts) do
    Enum.any?(parts, fn
      part when is_binary(part) -> part |> String.split() |> Enum.any?(&name_literal?/1)
      other -> ast_mention?(other)
    end)
  end

  # An interpolated string: its first literal part may be a name prefix
  # (`"Elixir.Nerves.#{x}"`); the interpolations are code.
  defp ast_mention?({:<<>>, _, [first | _] = parts}) when is_binary(first) do
    name_literal?(first) or Enum.any?(parts, &ast_mention?/1)
  end

  defp ast_mention?(text) when is_binary(text), do: name_literal?(text)

  defp ast_mention?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&ast_mention?/1)

  defp ast_mention?(list) when is_list(list) do
    if list != [] and Enum.all?(list, &is_integer/1),
      do: charlist_name?(list),
      else: Enum.any?(list, &ast_mention?/1)
  end

  defp ast_mention?(_other), do: false

  # A single-quoted charlist parses to a list of integers.
  defp charlist_name?(list) do
    case :unicode.characters_to_binary(list) do
      text when is_binary(text) -> name_literal?(text)
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  defp contains?(text), do: text |> String.downcase() |> String.contains?("nerves")

  @doc false
  # Runs `fun` in its own process under a heap cap and a timeout: deeply
  # nested or huge input kills that process, never the worker. `fun` returns
  # `{:ok, boolean}`; anything else, a crash, the cap or the timeout is
  # `:fallback`. The options exist for tests.
  @spec bounded((-> term()), keyword()) :: {:ok, boolean()} | :fallback
  def bounded(fun, opts \\ []) do
    max_heap = Keyword.get(opts, :max_heap_words, @parse_max_heap_words)
    timeout = Keyword.get(opts, :timeout_ms, @parse_timeout_ms)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: max_heap,
          kill: true,
          error_logger: false
        })

        exit({:done, fun.()})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:done, {:ok, found}}} when is_boolean(found) -> {:ok, found}
      {:DOWN, ^ref, :process, ^pid, _other} -> :fallback
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :fallback
        end
    end
  end

  @doc "Whether Erlang `source` names Nerves outside comments, strings and characters."
  @spec erlang_mention?(binary()) :: boolean()
  def erlang_mention?(source) when is_binary(source) do
    case bounded(fn -> erlang_code_mention(source) end) do
      {:ok, found} -> found and raw?(source)
      :fallback -> raw?(source)
    end
  end

  defp erlang_code_mention(source) do
    if String.contains?(source, ~s(""")) do
      :fallback
    else
      case lex(source, [], []) do
        {:ok, code, strings} ->
          {:ok, raw?(IO.iodata_to_binary(code)) or Enum.any?(strings, &name_literal?/1)}

        :fallback ->
          :fallback
      end
    end
  end

  # One left-to-right pass that jumps from one special character to the
  # next, so it is linear: plain text is kept, a comment, string or
  # character literal becomes a space, a quoted atom keeps its text. Each
  # string's content is collected for `name_literal?/1`. `code` is kept in
  # reverse; its order does not matter to a substring search because every
  # piece is separated by a space.
  defp lex(source, code, strings) do
    case :binary.match(source, @erlang_special) do
      :nomatch ->
        {:ok, [source | code], strings}

      {pos, 1} ->
        plain = binary_part(source, 0, pos)
        rest = binary_part(source, pos + 1, byte_size(source) - pos - 1)
        token(:binary.at(source, pos), rest, [" ", plain | code], strings)
    end
  end

  defp token(?%, rest, code, strings), do: lex(skip_line(rest), code, strings)
  defp token(?$, rest, code, strings), do: lex(skip_char(rest), code, strings)
  # A sigil (OTP 27+): not modelled.
  defp token(?~, _rest, _code, _strings), do: :fallback

  defp token(?", rest, code, strings) do
    case quoted(rest, ?", 0) do
      {content, rest} -> lex(rest, code, [content | strings])
      :unterminated -> :fallback
    end
  end

  defp token(?', rest, code, strings) do
    case quoted(rest, ?', 0) do
      {content, rest} -> lex(rest, [" ", content | code], strings)
      :unterminated -> :fallback
    end
  end

  defp skip_line(rest) do
    case :binary.match(rest, "\n") do
      {pos, 1} -> binary_part(rest, pos, byte_size(rest) - pos)
      :nomatch -> ""
    end
  end

  # The text up to the closing `quote`, skipping each backslash escape:
  # three bytes for a control escape (`\^X`), two for any other.
  defp quoted(source, quote, from) do
    size = byte_size(source)

    case :binary.match(source, [<<quote>>, "\\"], scope: {from, size - from}) do
      :nomatch ->
        :unterminated

      {pos, 1} ->
        cond do
          :binary.at(source, pos) == quote ->
            {binary_part(source, 0, pos), binary_part(source, pos + 1, size - pos - 1)}

          pos + 3 <= size and :binary.at(source, pos + 1) == ?^ ->
            quoted(source, quote, pos + 3)

          pos + 2 <= size ->
            quoted(source, quote, pos + 2)

          true ->
            :unterminated
        end
    end
  end

  # What follows `$`: `$\x{41}`, `$\101`, `$\^a`, `$\n`, or one character.
  defp skip_char(<<"\\x{", rest::binary>>) do
    case :binary.match(rest, "}") do
      {pos, 1} -> binary_part(rest, pos + 1, byte_size(rest) - pos - 1)
      :nomatch -> ""
    end
  end

  defp skip_char(<<"\\", digit, rest::binary>>) when digit in ?0..?7, do: skip_octal(rest, 2)
  defp skip_char(<<"\\^", _char, rest::binary>>), do: rest
  defp skip_char(<<"\\", _char::utf8, rest::binary>>), do: rest
  defp skip_char(<<_char::utf8, rest::binary>>), do: rest
  defp skip_char(<<_byte, rest::binary>>), do: rest
  defp skip_char(<<>>), do: <<>>

  defp skip_octal(<<digit, rest::binary>>, left) when left > 0 and digit in ?0..?7,
    do: skip_octal(rest, left - 1)

  defp skip_octal(rest, _left), do: rest
end
