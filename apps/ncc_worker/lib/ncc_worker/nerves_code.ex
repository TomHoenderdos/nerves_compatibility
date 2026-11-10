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
      identifier containing `nerves` (any case); interpolation is code,
      plain string, charlist and sigil contents and comments are not.
    * Erlang: comments, strings and character literals are blanked by a
      regex lexer (`erl_scan` creates atoms); any remaining text with
      `nerves` (any case) counts, quoted atoms included.

  Monotone: a file counts only when today's raw case-insensitive search
  (`BuildSelection`'s grep) finds `nerves` in it too, and a file over 2 MB,
  one that does not parse, or one whose parse is killed or times out uses
  that raw search. So this never refuses what rule 2 accepted before.
  """

  @max_file_bytes 2 * 1024 * 1024
  @parse_timeout_ms 5_000
  # About 256 MiB of heap on a 64-bit VM.
  @parse_max_heap_words 32 * 1024 * 1024
  @marker :__ncc_nerves_code_atom__
  @extensions ~w(.ex .exs .erl)

  @spec mention(String.t()) :: :found | :none | :missing | :error
  def mention(dir) do
    if File.dir?(dir), do: scan(dir), else: :missing
  end

  defp scan(dir) do
    case files(dir, dir) do
      {:ok, files} -> if Enum.any?(files, &file_mention?/1), do: :found, else: :none
      :error -> :error
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

      {:ok, %File.Stat{type: :regular}} ->
        {:ok, if(Path.extname(path) in @extensions, do: [path], else: [])}

      {:ok, _other} ->
        {:ok, []}

      {:error, _reason} ->
        :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp file_mention?(path) do
    case File.read(path) do
      {:ok, source} -> raw?(source) and code_mention?(path, source)
      {:error, _reason} -> throw(:unreadable)
    end
  end

  defp raw?(source), do: Regex.match?(~r/nerves/i, source)

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

  defp ast_mention?({@marker, token}) when is_binary(token),
    do: token |> String.downcase() |> String.contains?("nerves")

  defp ast_mention?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&ast_mention?/1)

  defp ast_mention?(list) when is_list(list), do: Enum.any?(list, &ast_mention?/1)
  defp ast_mention?(_other), do: false

  # Runs `fun` in its own process under a heap cap and a timeout: deeply
  # nested or huge input kills that process, never the worker.
  defp bounded(fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: @parse_max_heap_words,
          kill: true,
          error_logger: false
        })

        exit({:done, fun.()})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:done, {:ok, found}}} when is_boolean(found) -> {:ok, found}
      {:DOWN, ^ref, :process, ^pid, _other} -> :fallback
    after
      @parse_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :fallback
        end
    end
  end

  @doc "Whether Erlang `source` names Nerves outside comments, strings and characters."
  @spec erlang_mention?(binary()) :: boolean()
  def erlang_mention?(source) when is_binary(source) do
    code = Regex.replace(erlang_noise(), source, &keep_quoted_atom/1)
    Regex.match?(~r/nerves/i, code) and raw?(source)
  rescue
    _ -> raw?(source)
  end

  # One left-to-right pass, so a `%` inside a string or a `"` inside a
  # comment is consumed by the right alternative: a quoted atom (kept), a
  # string, a comment, a character literal (`$%`, `$"`, `$\n`, `$\x{41}`).
  defp erlang_noise,
    do:
      ~r/'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|%[^\n]*|\$(?:\\(?:x\{[0-9a-fA-F]*\}|[0-7]{1,3}|\^.|.)|.)/s

  defp keep_quoted_atom("'" <> _ = atom), do: atom
  defp keep_quoted_atom(_noise), do: " "
end
