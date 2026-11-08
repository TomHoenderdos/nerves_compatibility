defmodule Compatibility.ConfigVariants.PhxNew do
  @moduledoc """
  Reads the `:phoenix` and `:phoenix_live_view` keys out of phx_new's config
  templates (`templates/phx_single/config/*.exs.eex`) into the overlay each
  named config variant should carry, and compares them with the pinned ones
  (`Compatibility.ConfigVariants`).

  Only top-level `config :phoenix ...` and `config :phoenix_live_view ...`
  statements are read. EEx tags are removed first (keeping every branch:
  these keys sit in the `--live` branches), and a value must be a literal:
  nothing in a template is evaluated, and parsing one creates no atom (an
  atom the VM does not know reads as `{:unknown_atom, text}`, which never
  equals a pinned value).
  """

  alias Compatibility.ConfigVariants

  @apps [:phoenix, :phoenix_live_view]
  @envs %{"phx_prod" => "prod.exs", "phx_test" => "test.exs", "phx_dev" => "dev.exs"}

  @doc """
  The overlay each named variant gets from `templates`, a map of
  `config.exs`, `dev.exs`, `test.exs` and `prod.exs` to their template text:
  `config.exs` merged with the env's file, later statements winning.
  """
  @spec overlays(%{String.t() => String.t()}) :: %{String.t() => [term()]}
  def overlays(templates) do
    # The pinned table's atoms exist only once its module is loaded; before
    # that, every pinned key would read as unknown.
    Code.ensure_loaded!(ConfigVariants)

    base = statements(Map.fetch!(templates, "config.exs"))

    Map.new(@envs, fn {name, file} ->
      merged = Map.merge(base, statements(Map.fetch!(templates, file)))
      {name, for({{app, key}, value} <- merged, do: {app, key, value})}
    end)
  end

  @doc "How `templates` differ from the pinned overlays, one line each; `[]` when they match."
  @spec drift(%{String.t() => String.t()}) :: [String.t()]
  def drift(templates) do
    overlays = overlays(templates)

    Enum.flat_map(ConfigVariants.names(), fn name ->
      {:ok, pinned} = ConfigVariants.overlay(name)
      compare(name, Map.new(pinned, &pair/1), Map.new(overlays[name], &pair/1))
    end)
  end

  defp pair({app, key, value}), do: {{app, key}, value}

  defp compare(name, pinned, found) do
    extra =
      for {{app, key}, value} <- found,
          not Map.has_key?(pinned, {app, key}),
          do:
            "#{name}: #{text(app)} #{text(key)} set by phx_new, not by the overlay" <> note(value)

    missing =
      for {{app, key}, _} <- pinned,
          not Map.has_key?(found, {app, key}),
          do: "#{name}: #{app} #{key} set by the overlay, not by phx_new"

    differs =
      for {{app, key}, value} <- found,
          Map.has_key?(pinned, {app, key}),
          pinned[{app, key}] != value,
          do: "#{name}: #{app} #{key} " <> differs(value)

    Enum.sort(extra ++ missing ++ differs)
  end

  defp differs({:not_literal, code}), do: "is not a literal: #{code}"
  defp differs(_value), do: "differs"

  defp note({:not_literal, code}), do: " (not a literal: #{code})"
  defp note(_value), do: ""

  defp text({:unknown_atom, name}), do: name
  defp text(other), do: to_string(other)

  # `%{{app, key} => value}` of one template file, later statements winning.
  defp statements(text) do
    text
    |> String.replace(~r/<%=?\s*(if|else|end|unless|for|case)\b.*?%>/s, "")
    |> String.replace(~r/<%=.*?%>/s, "ncc_eex")
    |> String.replace(~r/<%.*?%>/s, "")
    |> top_level()
    |> Enum.flat_map(&read_statement/1)
    |> Map.new()
  end

  # Each top-level `config :phoenix...` statement: from its line to the next
  # line that starts at column 0.
  defp top_level(text) do
    text
    |> String.split("\n")
    |> Enum.chunk_while([], &chunk_line/2, fn acc -> {:cont, Enum.reverse(acc), []} end)
    |> Enum.map(&Enum.join(&1, "\n"))
    |> Enum.filter(&String.match?(&1, ~r/\Aconfig :phoenix(_live_view)?\b/))
  end

  defp chunk_line(line, acc) do
    if acc != [] and line != "" and not String.starts_with?(line, [" ", "\t"]),
      do: {:cont, Enum.reverse(acc), [line]},
      else: {:cont, [line | acc]}
  end

  defp read_statement(code) do
    case Code.string_to_quoted(code, static_atoms_encoder: &existing_atom/2) do
      {:ok, {:config, _, [app, key, value]}} when app in @apps and is_atom(key) ->
        [{{app, key}, literal(value)}]

      {:ok, {:config, _, [app, {:unknown_atom, _} = key, value]}} when app in @apps ->
        [{{app, key}, literal(value)}]

      {:ok, {:config, _, [app, kw]}} when app in @apps and is_list(kw) ->
        read_keyword(app, kw, code)

      _ ->
        [{{:unparsed, code}, {:not_literal, code}}]
    end
  end

  defp read_keyword(app, kw, code) do
    if Enum.all?(kw, &match?({_, _}, &1)),
      do: for({key, value} <- kw, do: {{app, key}, literal(value)}),
      else: [{{:unparsed, code}, {:not_literal, code}}]
  end

  defp existing_atom(token, _meta) do
    {:ok, String.to_existing_atom(token)}
  rescue
    ArgumentError -> {:ok, {:unknown_atom, token}}
  end

  defp literal(value) when is_binary(value) or is_number(value) or is_atom(value), do: value
  defp literal({:unknown_atom, _} = atom), do: atom

  defp literal({:__aliases__, _, parts} = alias) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: Module.safe_concat(parts),
      else: {:not_literal, show(alias)}
  rescue
    ArgumentError -> {:not_literal, show(alias)}
  end

  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(other), do: {:not_literal, show(other)}

  # An unknown atom is `{:unknown_atom, text}`, which Macro.to_string/1 may
  # not print; inspect/1 always can.
  defp show(ast) do
    Macro.to_string(ast)
  rescue
    _ -> inspect(ast)
  end
end
