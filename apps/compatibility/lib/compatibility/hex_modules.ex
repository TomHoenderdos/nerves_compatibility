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
  `Compatibility.StaticPriv.max_tarball_bytes/0` (or `:max_tarball`), its
  contents at 64 MiB inflated, 5,000 files and 32 MiB of parsed source.
  Never raises.
  """

  @max_contents_bytes 64 * 1024 * 1024
  @max_source_bytes 32 * 1024 * 1024
  @max_files 5_000

  @doc """
  The modules the Hex tarball `bytes` defines, as their atom names
  (`Elixir.Foo`, `foo_erl`); `[]` for anything `read/2` cannot read.
  """
  @spec modules(binary() | nil) :: [String.t()]
  def modules(bytes) do
    case read(bytes) do
      {:ok, %{modules: modules}} -> modules
      {:error, _why} -> []
    end
  end

  @doc """
  The modules the Hex tarball `bytes` defines and the application its
  `metadata.config` names, or why they cannot be known in full: a tarball
  or its contents over the caps, more files or more source than the caps
  allow, or a `.ex` file under `lib/` that does not parse. A leex or yecc
  file (`.xrl`, `.yrl`) defines the module of its base name. Options:
  `:max_tarball` (bytes, default `Compatibility.StaticPriv.max_tarball_bytes/0`).
  """
  @spec read(binary() | nil, keyword()) ::
          {:ok, %{modules: [String.t()], app: String.t() | nil}} | {:error, term()}
  def read(bytes, opts \\ [])

  def read(bytes, opts) when is_binary(bytes) do
    max = Keyword.get_lazy(opts, :max_tarball, &Compatibility.StaticPriv.max_tarball_bytes/0)

    with :ok <- if(byte_size(bytes) <= max, do: :ok, else: {:error, :tarball_too_large}),
         {:ok, outer} <- outer(bytes),
         {:ok, gz} <- Map.fetch(outer, "contents.tar.gz") |> found(:no_contents),
         {:ok, tar} <- inflate(gz),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) |> tar_files(),
         :ok <- if(length(files) <= @max_files, do: :ok, else: {:error, :too_many_files}),
         {:ok, modules} <- sources(files) do
      {:ok, %{modules: Enum.uniq(modules), app: app(Map.get(outer, "metadata.config"))}}
    end
  rescue
    e -> {:error, {:unreadable, Exception.message(e)}}
  end

  def read(_bytes, _opts), do: {:error, :not_a_tarball}

  defp outer(bytes) do
    case :erl_tar.extract({:binary, bytes}, [:memory]) do
      {:ok, files} -> {:ok, Map.new(files, fn {name, body} -> {List.to_string(name), body} end)}
      _ -> {:error, :not_a_tarball}
    end
  end

  defp found({:ok, value}, _why), do: {:ok, value}
  defp found(:error, why), do: {:error, why}

  defp inflate(gz) do
    case Compatibility.StaticPriv.inflate(gz, @max_contents_bytes) do
      {:ok, tar} -> {:ok, tar}
      _ -> {:error, :contents_too_large}
    end
  end

  defp tar_files({:ok, files}), do: {:ok, files}
  defp tar_files(_error), do: {:error, :contents_unreadable}

  defp sources(files) do
    Enum.reduce_while(files, {:ok, [], 0}, fn {name, body}, {:ok, acc, used} ->
      case source(List.to_string(name), body, used) do
        {:ok, found, used} -> {:cont, {:ok, found ++ acc, used}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, modules, _used} -> {:ok, modules}
      {:error, _} = error -> error
    end
  end

  defp source(name, body, used) do
    cond do
      String.ends_with?(name, [".ex", ".erl"]) and used + byte_size(body) > @max_source_bytes ->
        {:error, :source_too_large}

      String.ends_with?(name, ".ex") ->
        elixir_source(name, body, used)

      String.ends_with?(name, ".erl") ->
        {:ok, erlang_modules(body), used + byte_size(body)}

      String.ends_with?(name, [".xrl", ".yrl"]) ->
        {:ok, [Path.basename(name, Path.extname(name))], used}

      true ->
        {:ok, [], used}
    end
  end

  # A `.ex` file outside `lib/` that does not parse defines nothing; one in
  # `lib/` makes the tarball unreadable.
  defp elixir_source(name, body, used) do
    case elixir_modules(body) do
      {:ok, modules} ->
        {:ok, modules, used + byte_size(body)}

      :error ->
        if String.starts_with?(name, "lib/"),
          do: {:error, {:unparsed, name}},
          else: {:ok, [], used}
    end
  end

  # `{<<"app">>,<<"name">>}.`, read without creating atoms.
  defp app(meta) when is_binary(meta) do
    case Regex.run(~r/\{\s*<<"app">>\s*,\s*<<"([a-z][a-z0-9_]*)">>\s*\}/, meta) do
      [_, app] -> app
      _ -> nil
    end
  end

  defp app(_meta), do: nil

  defp erlang_modules(body) do
    case Regex.run(~r/^-module\(\s*'?([a-z][A-Za-z0-9_@]*)'?\s*\)/m, body) do
      [_, m] -> [m]
      _ -> []
    end
  end

  # No atom is created: every atom of the source comes back as {:atom, name}.
  defp elixir_modules(body) do
    with true <- String.valid?(body),
         {:ok, ast} <-
           Code.string_to_quoted(body,
             static_atoms_encoder: fn name, _meta -> {:ok, {:atom, name}} end,
             existing_atoms_only: true,
             columns: false,
             emit_warnings: false
           ) do
      {:ok, ast |> walk(nil, []) |> Enum.uniq()}
    else
      _ -> :error
    end
  rescue
    _ -> :error
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
