defmodule NccWorker.CompileError do
  @moduledoc """
  The first compiler error of a failed host compile, read from the tail of
  its log (`NccWorker.HostTrace`'s `log_tail`), which a toolchain build
  records as `compile_observations.compile_error`. The portal names it in
  the build's reason (`Compatibility.Portability.with_compile_error/2`),
  so a failed compile says why without its log, which is not kept.

  When the log holds a traced compile and the untraced one that gave the
  status (`HostTrace`'s fallback), only the last untraced one is read. Its
  lines are searched, in this order, for:

    1. a compiler's own error: an Elixir diagnostic (`error: ...`, with the
       file and line of the `└─` under it), an Erlang or C compiler's
       `file:line: message` that is not a warning, a note or a stacktrace
       entry, a shell's `...: not found` for a build program, or rebar3's
       `Compiling <file> failed` with the first message under it that is not
       a warning;
    2. an exception (`** (Error) message`), other than Mix's summary of a
       dependency that failed;
    3. Mix's account of a dependency it could not build (no app file, no
       build file);
    4. Mix's or rebar3's summary that a dependency failed.

  The first line of the first kind found is the error. The project dir is
  cut from every path, terminal colours are dropped, and the line is cut to
  #{1000} bytes of whole code points; bytes that are not UTF-8 are U+FFFD
  first. `nil` when nothing matches. Cleaning
  for display (paths, one line, the 200-byte bound) is the portal's.
  """

  @marker "==> the traced host compile is not the build"
  # An Erlang, leex, yecc or C-family compiler's `file:line[:col]: message`.
  # Not an Elixir file: Elixir reports an error as `error:`, and an Elixir
  # file's `file:line: ...` is a warning's or a stacktrace's location.
  @source_error ~r/\A(\S+\.(?:erl|hrl|xrl|yrl|c|h|cc|cpp|cxx|hpp|hh|m|mm)):(\d+)(?::\d+)?: (.+)\z/u
  @max_bytes 1000
  # How far below an error its location or message is looked for.
  @window 20

  @doc "The first compiler error in `log`, with `project_dir` cut from its paths, or nil."
  @spec first(String.t() | nil, String.t()) :: String.t() | nil
  def first(log, project_dir) when is_binary(log) and is_binary(project_dir) do
    lines =
      log
      |> untraced()
      |> String.replace_invalid()
      |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
      |> String.replace(String.trim_trailing(project_dir, "/") <> "/", "")
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim_trailing/1)

    indexed = Enum.with_index(lines)

    Enum.find_value([&compiler/2, &exception/2, &mix_dep/2, &summary/2], fn kind ->
      Enum.find_value(indexed, fn {line, i} -> kind.(line, Enum.drop(lines, i + 1)) end)
    end)
    |> bounded()
  end

  def first(_log, _project_dir), do: nil

  defp untraced(log) do
    case :binary.matches(log, @marker) do
      [] ->
        log

      matches ->
        {at, _} = List.last(matches)
        log |> binary_part(at, byte_size(log) - at) |> String.split("\n", parts: 2) |> tl_or("")
    end
  end

  defp tl_or([_marker, rest], _default), do: rest
  defp tl_or(_parts, default), do: default

  # An Elixir diagnostic, a `file:line: message`, or rebar3's failed file.
  defp compiler(line, below) do
    trimmed = line |> String.trim() |> String.replace_prefix("===> ", "")

    cond do
      String.starts_with?(trimmed, "error: ") ->
        trimmed <> location(below)

      match = Regex.run(@source_error, trimmed) ->
        [_, file, number, message] = match
        unless warning?(message) or mfa?(message), do: "#{file}:#{number}: #{message}"

      Regex.match?(~r/\A\S*sh: (?:line )?\d+: .+: (?:command )?not found\z/u, trimmed) ->
        trimmed

      match = Regex.run(~r/\ACompiling (\S+) failed\z/u, trimmed) ->
        case rebar_message(below) do
          nil -> nil
          message -> "Compiling #{Enum.at(match, 1)} failed: #{message}"
        end

      true ->
        nil
    end
  end

  # A stacktrace entry's function (`Mod.fun/1`, `:mod.fun/2`, `mod:fun/2`).
  defp mfa?(message), do: Regex.match?(~r/\A:?[\w.]+[.:][\w!?]+\/\d+\z/u, message)

  defp warning?(message),
    do: Regex.match?(~r/\A(?:Warning|warning|note|In file included)\b/u, message)

  # The `└─ file:line:col: ...` of an Elixir diagnostic, before the next one.
  defp location(below) do
    below
    |> Enum.take(@window)
    |> Enum.take_while(&(not Regex.match?(~r/\A\s*(?:error|warning): /u, &1)))
    |> Enum.find_value("", fn line ->
      case Regex.run(~r/└─ (\S+?):(\d+)/u, line) do
        [_, file, number] -> " (#{file}:#{number})"
        nil -> nil
      end
    end)
  end

  # The first `╰── message` under rebar3's failed file that is not a warning.
  defp rebar_message(below) do
    below
    |> Enum.take(@window)
    |> Enum.find_value(&rebar_error/1)
  end

  defp rebar_error(line) do
    case Regex.run(~r/╰── (.+)\z/u, line) do
      [_, message] -> if warning?(message), do: nil, else: message
      nil -> nil
    end
  end

  @summaries ["Can't continue due to errors on dependencies", "Could not compile dependency "]

  defp exception(line, _below) do
    trimmed = String.trim(line)

    if Regex.match?(~r/\A\*\* \(\S+\) \S/u, trimmed) and
         not Enum.any?(@summaries, &String.contains?(trimmed, &1)),
       do: trimmed
  end

  defp mix_dep(line, _below) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, ["could not find an app file at ", "Could not compile :"]),
      do: trimmed
  end

  defp summary(line, _below) do
    trimmed = line |> String.trim() |> String.replace_prefix("===> ", "")

    cond do
      String.starts_with?(trimmed, "could not compile dependency ") ->
        trimmed |> String.split(". ", parts: 2) |> hd() |> String.trim_trailing(".")

      Regex.match?(~r/\ACompiling \S+ failed\z/u, trimmed) ->
        trimmed

      String.starts_with?(trimmed, "** (Mix) ") ->
        trimmed |> String.split(". ", parts: 2) |> hd()

      true ->
        nil
    end
  end

  defp bounded(nil), do: nil
  defp bounded(text) when byte_size(text) <= @max_bytes, do: text

  defp bounded(text) do
    text
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn cp, {acc, used} ->
      if used + byte_size(cp) <= @max_bytes,
        do: {:cont, {[cp | acc], used + byte_size(cp)}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
