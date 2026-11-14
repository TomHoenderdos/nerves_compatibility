defmodule NccWorker.TargetScan do
  @moduledoc """
  What of one source file of the package under test the rule-2 target-read
  grep (`NccWorker.BuildCache.dep_target_agnostic_rule2?/4`, `own: true`)
  looks at: only code that can run while the package compiles (judge round
  2, change 4b).

    * A doc file (`*.md`, `*.markdown`, `*.txt`, `LICENSE*`) is skipped
      (`nil`): nothing compiles it.
    * Any file named `mix.exs`, and every file that is not `.ex`/`.exs`
      (`.erl`, `.hrl`, `rebar.config*`, `.eex`, ...), is looked at whole.
    * Any other `.ex`/`.exs` file is parsed under `MixExsSlice.quoted/1`'s
      bounds and printed back without what cannot run at compile time: the
      bodies and guards of `def`/`defp` (an `unquote` or `unquote_splicing`
      fragment in one stays, as it runs when the module compiles), a
      `@doc`/`@moduledoc`/`@typedoc` whose value is a literal, and comments
      (the parser drops them). Module-level code, attributes, macro bodies
      (`quote` blocks included) and strings outside those stay. The
      caller matches its target-read pattern on that text.
    * A file that does not parse, is over the bounds, or cannot be printed
      back is looked at whole.

  Erring towards the whole file only costs a precompiled build.
  """

  alias NccWorker.Portability.MixExsSlice

  @doc_exts ~w(.md .markdown .txt)
  @doc_attrs [:doc, :moduledoc, :typedoc]

  @doc """
  The text of `path` (whose contents are `contents`) the target-read
  pattern is matched on, or `nil` when nothing in it can run at compile
  time.
  """
  @spec scanned(String.t(), binary()) :: binary() | nil
  def scanned(path, contents) when is_binary(path) and is_binary(contents) do
    base = Path.basename(path)

    cond do
      doc_file?(base) -> nil
      base == "mix.exs" -> contents
      Path.extname(base) in [".ex", ".exs"] -> compile_time_text(contents)
      true -> contents
    end
  end

  defp doc_file?(base),
    do: String.downcase(Path.extname(base)) in @doc_exts or String.starts_with?(base, "LICENSE")

  defp compile_time_text(contents) do
    case MixExsSlice.quoted(contents) do
      {:ok, ast} -> ast |> Macro.prewalk(&compile_time/1) |> Macro.to_string()
      :error -> contents
    end
  rescue
    _ -> contents
  end

  # A `def`/`defp` keeps only its unquote fragments; a literal doc goes.
  defp compile_time({kind, _meta, [_ | _] = args}) when kind in [:def, :defp],
    do: {:__block__, [], unquotes(args)}

  defp compile_time({:@, _meta, [{attr, _, [value]}]} = node) when attr in @doc_attrs,
    do: if(literal?(value), do: nil, else: node)

  defp compile_time(node), do: node

  defp unquotes(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {fun, _, [_]} = node, acc when fun in [:unquote, :unquote_splicing] ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # A doc value that runs nothing: a string, heredoc or `~s`/`~S` sigil
  # without interpolation, `false`, an atom, a number, or a keyword list of those
  # (`@doc since: "1.0"`).
  defp literal?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?({key, value}), do: literal?(key) and literal?(value)

  defp literal?({sigil, _, [{:<<>>, _, parts}, modifiers]})
       when sigil in [:sigil_s, :sigil_S] and is_list(parts) and is_list(modifiers),
       do: Enum.all?(parts, &is_binary/1)

  defp literal?(_value), do: false
end
