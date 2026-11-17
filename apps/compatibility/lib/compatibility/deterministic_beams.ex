defmodule Compatibility.DeterministicBeams do
  @moduledoc """
  The deterministic sibling of a toolchain build (`docs/superpowers` design
  addendum, option (a)): the same package, closure and toolchain compiled
  again with `ERL_COMPILER_OPTIONS=deterministic`, which a client takes only
  when its own project sets exactly that option. The sibling is a real
  compile, so its beams are what a user's own deterministic compile gives;
  this module is the check that the option changed only what it is known to
  change, run by the worker before it records a sibling and by the portal
  again at ingest. Anything else drops the sibling, never the build.

  `compare_ebin/2` takes the two builds' `ebin` files, `%{path => bytes}`:

    * the same file names;
    * every file that is not a `.beam` (the `.app` among them) byte for byte
      the same;
    * every beam the same module, compiled with the option: its `CInf` has
      neither `options` nor `source` (`compile:compile_info/3` leaves both
      out under `deterministic`), so a compile the option never reached
      cannot pass for one it did;
    * the same chunk ids, with the chunks that differ inside the set the
      option is known to touch, by the module's language (its `Dbgi`
      backend, the same in both):
      * an Elixir module (`elixir_erl`): `CInf`, `Dbgi`, `Docs` and `ExCk`
        alone, and the same `beam_lib:md5/1`. Its code, literals, line
        table and attributes are those of the build without the option;
      * an Erlang module (`erl_abstract_code`): `CInf`, `Dbgi`, `Docs`,
        `Line`, `LitT` and `Attr`. The option gives epp the source's base
        name, which is the line table's file and `?FILE`, so the literal
        table, the md5 and with it the default `vsn` change; the code does
        not;
      * any other backend, or no `Dbgi`: held to the Elixir rule.

  Never raises.
  """

  @options ["deterministic"]
  @env_name "ERL_COMPILER_OPTIONS"
  @env_value "deterministic"

  @elixir_chunks ~w(CInf Dbgi Docs ExCk)
  @erlang_chunks ~w(CInf Dbgi Docs Line LitT Attr)

  @doc "The `build.erl_compiler_options` a deterministic sibling carries."
  @spec options() :: [String.t()]
  def options, do: @options

  @doc "The environment variable a sibling is compiled with, and its value."
  @spec env() :: {String.t(), String.t()}
  def env, do: {@env_name, @env_value}

  @doc "The variable's name."
  @spec env_name() :: String.t()
  def env_name, do: @env_name

  @doc "Checks a sibling's `ebin` against its build's (see the moduledoc)."
  @spec compare_ebin(%{String.t() => binary()}, %{String.t() => binary()}) ::
          :ok | {:error, String.t()}
  def compare_ebin(normal, sibling) when is_map(normal) and is_map(sibling) do
    names = normal |> Map.keys() |> Enum.sort()

    cond do
      names != sibling |> Map.keys() |> Enum.sort() ->
        {:error, "the sibling's ebin holds other files"}

      names == [] ->
        {:error, "no ebin files"}

      true ->
        Enum.reduce_while(names, :ok, &compare_named(&1, &2, normal, sibling))
    end
  end

  def compare_ebin(_normal, _sibling), do: {:error, "no ebin files"}

  defp compare_named(name, :ok, normal, sibling) do
    case compare_file(name, Map.fetch!(normal, name), Map.fetch!(sibling, name)) do
      :ok -> {:cont, :ok}
      {:error, why} -> {:halt, {:error, "#{name}: #{why}"}}
    end
  end

  defp compare_file(name, normal, sibling) when is_binary(normal) and is_binary(sibling) do
    cond do
      Path.extname(name) == ".beam" -> compare_beam(normal, sibling)
      normal == sibling -> :ok
      true -> {:error, "differs"}
    end
  end

  defp compare_file(_name, _normal, _sibling), do: {:error, "unreadable"}

  @doc "Checks one sibling beam against its build's (see the moduledoc)."
  @spec compare_beam(binary(), binary()) :: :ok | {:error, String.t()}
  def compare_beam(normal, sibling) when is_binary(normal) and is_binary(sibling) do
    with {:ok, module, a} <- chunks(normal),
         {:ok, ^module, b} <- chunks(sibling) |> same_module(module),
         :ok <- deterministic_info(sibling),
         :ok <- same_ids(a, b) do
      kind = kind(normal, sibling)
      differ = for {id, bytes} <- a, List.keyfind(b, id, 0) != {id, bytes}, do: id

      case differ -- allowed(kind) do
        [] -> md5(kind, normal, sibling)
        ids -> {:error, "chunks #{Enum.join(ids, ", ")} differ"}
      end
    end
  rescue
    _ -> {:error, "unreadable beam"}
  end

  def compare_beam(_normal, _sibling), do: {:error, "unreadable beam"}

  defp chunks(bytes) do
    case :beam_lib.all_chunks(bytes) do
      {:ok, module, chunks} ->
        ids = for {id, data} <- chunks, do: {List.to_string(id), data}
        {:ok, module, ids}

      _ ->
        {:error, "unreadable beam"}
    end
  end

  defp same_module({:ok, module, _} = ok, module), do: ok
  defp same_module({:ok, _other, _}, _module), do: {:error, "another module"}
  defp same_module(error, _module), do: error

  defp deterministic_info(bytes) do
    case :beam_lib.chunks(bytes, [:compile_info]) do
      {:ok, {_, [compile_info: info]}} when is_list(info) ->
        if Keyword.has_key?(info, :source) or Keyword.has_key?(info, :options),
          do: {:error, "not compiled with the option"},
          else: :ok

      _ ->
        {:error, "no compile info"}
    end
  end

  defp same_ids(a, b) do
    if Enum.map(a, &elem(&1, 0)) |> Enum.sort() == Enum.map(b, &elem(&1, 0)) |> Enum.sort(),
      do: :ok,
      else: {:error, "other chunks"}
  end

  defp kind(normal, sibling) do
    case {backend(normal), backend(sibling)} do
      {:elixir_erl, :elixir_erl} -> :elixir
      {:erl_abstract_code, :erl_abstract_code} -> :erlang
      _ -> :other
    end
  end

  defp backend(bytes) do
    case :beam_lib.chunks(bytes, [:debug_info]) do
      {:ok, {_, [debug_info: {:debug_info_v1, backend, _}]}} -> backend
      _ -> nil
    end
  end

  defp allowed(:erlang), do: @erlang_chunks
  defp allowed(_kind), do: @elixir_chunks

  defp md5(:erlang, _normal, _sibling), do: :ok

  defp md5(_kind, normal, sibling) do
    if :beam_lib.md5(normal) == :beam_lib.md5(sibling),
      do: :ok,
      else: {:error, "md5 differs"}
  end
end
