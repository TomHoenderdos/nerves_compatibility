defmodule Compatibility.HexModules do
  @moduledoc """
  The modules a Hex tarball's sources define, shared by the worker's judge
  (`NccWorker.Portability.Declared`: a declared-absent dependency's
  modules) and the portal's module index (`Portal.Catalog.ModuleIndex`: the
  modules each popular package's latest release defines).

  Every literal `defmodule`, `defprotocol` and `defimpl` name in the
  tarball's `.ex` sources (an implementation is `Protocol.For`), parsed
  without creating atoms, and every `-module` of its `.erl` sources. A
  module a macro defines is not found. Bounded: the tarball at
  `Compatibility.StaticPriv.max_tarball_bytes/0`, its contents at 64 MiB
  inflated, 5,000 files and 32 MiB of parsed source. Never raises: anything
  unreadable defines nothing.
  """

  @max_contents_bytes 64 * 1024 * 1024
  @max_source_bytes 32 * 1024 * 1024
  @max_files 5_000

  @doc "The modules the Hex tarball `bytes` defines, as their atom names (`Elixir.Foo`, `foo_erl`)."
  @spec modules(binary() | nil) :: [String.t()]
  def modules(bytes) when is_binary(bytes) do
    with true <- byte_size(bytes) <= Compatibility.StaticPriv.max_tarball_bytes(),
         {:ok, [{_name, gz}]} <-
           :erl_tar.extract({:binary, bytes}, [:memory, {:files, [~c"contents.tar.gz"]}]),
         {:ok, tar} <- Compatibility.StaticPriv.inflate(gz, @max_contents_bytes),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      files
      |> Enum.take(@max_files)
      |> Enum.reduce({[], 0}, fn {name, body}, {acc, used} ->
        source(List.to_string(name), body, acc, used)
      end)
      |> elem(0)
      |> Enum.uniq()
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  def modules(_bytes), do: []

  defp source(_name, body, acc, used) when used + byte_size(body) > @max_source_bytes,
    do: {acc, used}

  defp source(name, body, acc, used) do
    cond do
      String.ends_with?(name, ".ex") and String.valid?(body) ->
        {elixir_modules(body) ++ acc, used + byte_size(body)}

      String.ends_with?(name, ".erl") ->
        {erlang_modules(body) ++ acc, used + byte_size(body)}

      true ->
        {acc, used}
    end
  end

  defp erlang_modules(body) do
    case Regex.run(~r/^-module\(\s*'?([a-z][A-Za-z0-9_@]*)'?\s*\)/m, body) do
      [_, m] -> [m]
      _ -> []
    end
  end

  # No atom is created: every atom of the source comes back as {:atom, name}.
  defp elixir_modules(body) do
    case Code.string_to_quoted(body,
           static_atoms_encoder: fn name, _meta -> {:ok, {:atom, name}} end,
           existing_atoms_only: true,
           columns: false,
           emit_warnings: false
         ) do
      {:ok, ast} -> ast |> walk(nil, []) |> Enum.uniq()
      _ -> []
    end
  rescue
    _ -> []
  end

  defp walk({{:atom, kind}, _, [name_ast | rest]}, outer, acc)
       when kind in ["defmodule", "defprotocol"] do
    case alias_name(name_ast, outer) do
      nil -> walk(rest, outer, acc)
      name -> walk(rest, name, [name | acc])
    end
  end

  defp walk({{:atom, "defimpl"}, _, [proto_ast | rest]}, outer, acc) do
    proto = alias_name(proto_ast, nil)
    fors = rest |> Enum.filter(&is_list/1) |> Enum.flat_map(&for_option/1)
    fors = if fors == [] and outer, do: [outer], else: Enum.map(fors, &alias_name(&1, nil))

    impls =
      for f <- fors,
          is_binary(proto) and is_binary(f),
          do: proto <> "." <> String.replace_prefix(f, "Elixir.", "")

    walk(rest, outer, impls ++ acc)
  end

  defp walk({a, _meta, args}, outer, acc), do: walk(args, outer, walk(a, outer, acc))
  defp walk({l, r}, outer, acc), do: walk(r, outer, walk(l, outer, acc))
  defp walk(list, outer, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, outer, &2))
  defp walk(_other, _outer, acc), do: acc

  defp for_option(kw) do
    Enum.flat_map(kw, fn
      {key, value} when key in [:for, {:atom, "for"}] -> List.wrap(value)
      _ -> []
    end)
  end

  # A literal alias, nested under the enclosing module unless it starts at
  # `Elixir`; `__MODULE__` or anything dynamic names nothing.
  defp alias_name({:__aliases__, _, parts}, outer) do
    names = for {:atom, p} <- parts, do: p

    cond do
      length(names) != length(parts) -> nil
      hd(names) == "Elixir" -> Enum.join(names, ".")
      is_binary(outer) -> outer <> "." <> Enum.join(names, ".")
      true -> "Elixir." <> Enum.join(names, ".")
    end
  end

  defp alias_name({:atom, name}, _outer), do: name
  defp alias_name(_other, _outer), do: nil
end
