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
    * With `erlang: :runtime` (`native_side: true`, the caller having found
      no parse or core transform in the package), an `.erl` or `.hrl` file
      is skipped (`nil`): nothing in it runs at compile time.

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
  @spec scanned(String.t(), binary(), keyword()) :: binary() | nil
  def scanned(path, contents, opts \\ []) when is_binary(path) and is_binary(contents) do
    base = Path.basename(path)

    cond do
      doc_file?(path) -> nil
      base == "mix.exs" -> contents
      Path.extname(base) in [".ex", ".exs"] -> compile_time_text(contents)
      erlang_runtime?(base, opts) -> nil
      true -> contents
    end
  end

  # `erlang: :runtime` (`native_side: true`, for a package with no parse or
  # core transform, which the caller checks): an Erlang source or header
  # runs nothing while the package compiles. Erlang has no compile-time
  # evaluation but a transform: an attribute holds terms, a macro expands
  # where it is used, a function runs when called, and a call made at
  # compile time from an Elixir module body is the trace's (its `mix_state`
  # channel refuses a target read wherever it is made). A `.script`, `.src`
  # or `rebar.config` is evaluated or consulted at build time and stays
  # whole.
  defp erlang_runtime?(base, opts),
    do: Keyword.get(opts, :erlang) == :runtime and Path.extname(base) in [".erl", ".hrl"]

  @doc """
  Whether `path` is a doc file (`*.md`, `*.markdown`, `*.txt`, `LICENSE*`),
  which nothing compiles. The trace's native classification of the package
  under test skips these too (`NccWorker.NativeBuild.split/4`).
  """
  @spec doc_file?(String.t()) :: boolean()
  def doc_file?(path) when is_binary(path) do
    base = Path.basename(path)
    String.downcase(Path.extname(base)) in @doc_exts or String.starts_with?(base, "LICENSE")
  end

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
