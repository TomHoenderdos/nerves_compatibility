defmodule Portal.Pins.Lock do
  @moduledoc """
  Reads a project's `mix.lock` on the portal host without evaluating it
  (the worker evaluates locks only inside its container): the text is
  quoted with every atom encoded as data, never interned, and only literals
  are read back. Anything that is not a literal map of lock entries is
  refused.

  Each entry comes back as `%{source: :hex, hex, version, managers, deps,
  repo, checksum}`, with `deps` as `%{app, hex, requirement, optional}`, or
  as `%{source: :git | :path | :other}` for an entry that is not a Hex
  release.
  """

  @marker :__lock_atom__
  @max_bytes 2 * 1024 * 1024

  @type entry :: %{required(:source) => :hex | :git | :path | :other, optional(atom()) => term()}

  @doc "`{:ok, %{app => entry}}`, or `{:error, reason}` for anything but a literal lock."
  @spec parse(String.t()) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def parse(content) when is_binary(content) and byte_size(content) <= @max_bytes do
    encoder = fn name, _meta -> {:ok, {@marker, name}} end

    with {:ok, quoted} <-
           Code.string_to_quoted(content, static_atoms_encoder: encoder, emit_warnings: false),
         {:ok, %{} = lock} <- literal(quoted) do
      entries(lock)
    else
      {:ok, _other} -> {:error, :not_a_map}
      {:error, {:not_literal, _} = reason} -> {:error, reason}
      {:error, _syntax} -> {:error, :unparsable}
    end
  end

  def parse(content) when is_binary(content), do: {:error, :too_large}

  defp entries(lock) do
    Enum.reduce_while(lock, {:ok, %{}}, fn
      {app, entry}, {:ok, acc} when is_binary(app) ->
        {:cont, {:ok, Map.put(acc, app, entry(entry))}}

      {key, _entry}, _acc ->
        {:halt, {:error, {:bad_key, key}}}
    end)
  end

  defp entry({"hex", hex, version, _inner, managers, deps, repo, checksum})
       when is_binary(hex) and is_binary(version) and is_list(managers) and is_list(deps) and
              is_binary(repo) and is_binary(checksum) do
    case dep_list(deps) do
      {:ok, deps} ->
        %{
          source: :hex,
          hex: hex,
          version: version,
          managers: Enum.filter(managers, &is_binary/1),
          deps: deps,
          repo: repo,
          checksum: checksum
        }

      :error ->
        %{source: :other}
    end
  end

  defp entry(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    case elem(tuple, 0) do
      "git" -> %{source: :git}
      "path" -> %{source: :path}
      _ -> %{source: :other}
    end
  end

  defp entry(_entry), do: %{source: :other}

  defp dep_list(deps) do
    Enum.reduce_while(deps, {:ok, []}, fn
      {app, requirement, opts}, {:ok, acc}
      when is_binary(app) and is_binary(requirement) and is_list(opts) ->
        opts = for {key, value} <- opts, is_binary(key), into: %{}, do: {key, value}

        dep = %{
          app: app,
          hex: if(is_binary(opts["hex"]), do: opts["hex"], else: app),
          requirement: requirement,
          optional: opts["optional"] == true,
          repo: if(is_binary(opts["repo"]), do: opts["repo"], else: "hexpm")
        }

        {:cont, {:ok, [dep | acc]}}

      _dep, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, deps} -> {:ok, Enum.reverse(deps)}
      :error -> :error
    end
  end

  # The quoted form back to a term: atoms (encoded by `parse/1`) as their
  # names, maps, tuples, lists, strings, numbers and booleans. Anything else
  # (a call, a variable, an interpolation) is not a literal.
  defp literal({@marker, name}) when is_binary(name), do: {:ok, name}
  defp literal({:%{}, _meta, pairs}) when is_list(pairs), do: pairs |> all() |> map(&Map.new/1)

  defp literal({:{}, _meta, elems}) when is_list(elems),
    do: elems |> all() |> map(&List.to_tuple/1)

  defp literal({a, b}) do
    with {:ok, a} <- literal(a), {:ok, b} <- literal(b), do: {:ok, {a, b}}
  end

  defp literal(list) when is_list(list), do: all(list)

  defp literal(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  defp literal(nil), do: {:ok, nil}
  defp literal(other), do: {:error, {:not_literal, inspect(other, limit: 5, printable_limit: 80)}}

  defp all(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> map(&Enum.reverse/1)
  end

  defp map({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map(error, _fun), do: error
end
