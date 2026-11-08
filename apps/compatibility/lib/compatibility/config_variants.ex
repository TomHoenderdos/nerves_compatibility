defmodule Compatibility.ConfigVariants do
  @phx_new "1.8.16"

  @moduledoc """
  The config variants a toolchain build is also made in (precompiled
  portability spec, R7): named, pinned config overlays that the worker writes
  into the plain project's `config/config.exs` before the traced compile.

  Nothing else differs from the `default` build: same image, same lock, the
  dependency compiled as `prod`. A variant's `compile_env` is what its own
  trace records (R5), never the overlay copied in. A client takes the variant
  whose recorded values equal its project's config.

  The overlays are the app-independent `:phoenix` and `:phoenix_live_view`
  keys that `mix phx.new` #{@phx_new} writes for each env, merged as a
  project loads them (`config.exs`, then the env's file). `phx_prod` is
  `config.exs` alone (`prod.exs` sets none of these keys).

  A named variant is wanted for a version only when its overlay, cut down to
  the `{app, key}` pairs the version's `default` build read, is not empty
  and differs from every earlier variant's cut-down overlay (`wanted/2`): a
  key the default compile never read cannot have changed it.
  """

  @prod [
    {:phoenix, :json_library, Jason},
    {:phoenix_live_view, :root_tag_attribute, "phx-r"}
  ]

  @variants [
    {"phx_prod", @prod},
    {"phx_test",
     @prod ++
       [
         {:phoenix, :plug_init_mode, :runtime},
         {:phoenix, :sort_verified_routes_query_params, true},
         {:phoenix_live_view, :enable_expensive_runtime_checks, true}
       ]},
    {"phx_dev",
     @prod ++
       [
         {:phoenix, :stacktrace_depth, 20},
         {:phoenix, :plug_init_mode, :runtime},
         {:phoenix_live_view, :debug_heex_annotations, true},
         {:phoenix_live_view, :debug_attributes, true},
         {:phoenix_live_view, :enable_expensive_runtime_checks, true}
       ]}
  ]

  @names Enum.map(@variants, &elem(&1, 0))

  @type item :: {atom(), atom(), term()}
  @type read :: {String.t(), String.t()}

  @doc "The variant every build without an overlay is."
  @spec default() :: String.t()
  def default, do: "default"

  @doc "The named variants, in rank order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Whether `name` is `default/0` or a named variant."
  @spec known?(term()) :: boolean()
  def known?(name), do: name == default() or name in @names

  @doc "The phx_new release the overlays are taken from."
  @spec phx_new_version() :: String.t()
  def phx_new_version, do: @phx_new

  @doc "The overlay of `name`; `{:ok, []}` for `default/0`."
  @spec overlay(term()) :: {:ok, [item()]} | :error
  def overlay("default"), do: {:ok, []}

  def overlay(name) do
    case List.keyfind(@variants, name, 0) do
      {^name, items} -> {:ok, items}
      nil -> :error
    end
  end

  @doc "The `compile_env` value of `{:ok, value}`, as a client decodes it."
  @spec encode(term()) :: String.t()
  def encode(value),
    do:
      {:ok, value}
      |> :erlang.term_to_binary([:deterministic])
      |> Base.url_encode64(padding: false)

  @doc "The `{app, key}` pairs a build's `compile_env` read: each item's app and first path element."
  @spec reads([map()] | nil) :: [read()]
  def reads(compile_env) when is_list(compile_env) do
    for %{"app" => app, "path" => [key | _]} <- compile_env, do: {app, key}
  end

  def reads(_compile_env), do: []

  @doc """
  The named variants wanted for a default build that read `reads`, among
  `enabled` (in pinned rank order): a non-empty cut-down overlay, the first
  variant of each distinct one.
  """
  @spec wanted([read()], [String.t()]) :: [String.t()]
  def wanted(reads, enabled \\ @names) do
    read = MapSet.new(reads)

    enabled
    |> enabled_variants()
    |> Enum.map(fn {name, items} -> {name, cut(items, read)} end)
    |> Enum.reject(fn {_name, cut} -> cut == [] end)
    |> Enum.uniq_by(fn {_name, cut} -> cut end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The enabled overlays as rows for the backlog's SQL: `{name, rank, app,
  key, item}`, `rank` from 1 in pinned order among `enabled`, `item` the text
  two rows compare equal on (`"app key encoded-value"`).
  """
  @spec rows([String.t()]) :: [
          {String.t(), pos_integer(), String.t(), String.t(), String.t()}
        ]
  def rows(enabled) do
    enabled
    |> enabled_variants()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{name, items}, rank} ->
      for {app, key, _value} = item <- items,
          do: {name, rank, Atom.to_string(app), Atom.to_string(key), item_text(item)}
    end)
  end

  @doc """
  Whether a named variant's `compile_env` shows its overlay was in effect: at
  least one overlay key recorded, and every recorded one at the overlay's
  value.
  """
  @spec overlay_recorded(String.t(), [map()] | nil) :: :ok | {:error, String.t()}
  def overlay_recorded(name, compile_env) do
    {:ok, items} = overlay(name)
    by_key = Map.new(items, fn {app, key, value} -> {{"#{app}", "#{key}"}, encode(value)} end)

    recorded =
      for %{"app" => app, "path" => [key], "value" => value} <- List.wrap(compile_env),
          Map.has_key?(by_key, {app, key}),
          do: {app, key, value}

    case Enum.find(recorded, fn {app, key, value} -> by_key[{app, key}] != value end) do
      _ when recorded == [] -> {:error, "config variant did not record its overlay"}
      nil -> :ok
      {app, key, _} -> {:error, "config variant recorded #{app} #{key} with another value"}
    end
  end

  @doc "A `config/config.exs` that sets exactly `items`."
  @spec render([item()]) :: String.t()
  def render(items) do
    body =
      items
      |> Enum.group_by(&elem(&1, 0), fn {_app, key, value} -> {key, value} end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {app, kw} ->
        "config #{inspect(app)}, #{inspect(Enum.sort(kw), limit: :infinity, printable_limit: :infinity)}"
      end)

    "import Config\n\n" <> body <> "\n"
  end

  defp enabled_variants(enabled), do: Enum.filter(@variants, fn {name, _} -> name in enabled end)

  defp cut(items, read) do
    items
    |> Enum.filter(fn {app, key, _} -> MapSet.member?(read, {"#{app}", "#{key}"}) end)
    |> Enum.map(&item_text/1)
    |> Enum.sort()
  end

  defp item_text({app, key, value}), do: "#{app} #{key} #{encode(value)}"
end
