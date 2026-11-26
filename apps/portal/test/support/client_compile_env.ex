defmodule Portal.Test.ClientCompileEnv do
  @moduledoc """
  The client's `compile_env` comparison, as precompiled 0.9.0 makes it in
  the user's Mix VM (`Precompiled.CompileEnv.lookup/2`,
  `Precompiled.Match.compile_env_reason/2` and `recorded_equals?/2`): each
  item's recorded value must be exactly (`===`) what `Application.fetch_env/2`
  of its app and first key gives here, followed down the rest of its path; an
  app or key that was never an atom in this VM is unset (`:error`). Run in
  the test VM, which has `:logger` and `:elixir` loaded as a user's Mix VM
  has, with no config of either key set.
  """

  @doc "The items of `items` this VM's config does not match."
  @spec misses([map()]) :: [map()]
  def misses(items) when is_list(items) do
    Enum.reject(items, fn %{"app" => app, "path" => path, "value" => value} ->
      recorded(value) === lookup(app, path)
    end)
  end

  @doc "The value a published item must carry to match this VM's `app` `key`."
  @spec value(String.t(), String.t()) :: String.t()
  def value(app, key),
    do:
      lookup(app, [key])
      |> :erlang.term_to_binary([:deterministic])
      |> Base.url_encode64(padding: false)

  defp recorded(value) do
    with {:ok, bin} <- Base.url_decode64(value, padding: false) do
      :erlang.binary_to_term(bin, [:safe])
    end
  rescue
    ArgumentError -> :undecodable
  end

  defp lookup(app, [first | rest]) do
    with {:ok, app} <- existing(app),
         {:ok, first} <- existing(first),
         {:ok, value} <- Application.fetch_env(app, first) do
      Enum.reduce_while(rest, {:ok, value}, &step/2)
    end
  end

  defp step(key, {:ok, value}) do
    with {:ok, key} <- existing(key) do
      case value do
        list when is_list(list) ->
          if Keyword.keyword?(list) and Keyword.has_key?(list, key),
            do: {:cont, {:ok, list[key]}},
            else: {:halt, :error}

        %{} = map ->
          if Map.has_key?(map, key), do: {:cont, {:ok, map[key]}}, else: {:halt, :error}

        _ ->
          {:halt, :error}
      end
    else
      :error -> {:halt, :error}
    end
  end

  defp existing(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
