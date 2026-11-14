defmodule Compatibility.Worlds do
  @phx_new "1.8.16"

  @moduledoc """
  The worlds a toolchain build is also made in: named, pinned sets of Hex
  package names that a common real application has in its prod env.

  A world build of package P is P compiled in a plain project to which the
  worker adds, at every depth of P's closure, each optional dependency that
  is a member of the world, until nothing changes. Its closure is then the
  one Mix gives P in any application whose present packages agree with the
  world on P's optional dependencies.

  `phx` is the prod package set of a `mix phx.new` #{@phx_new} application.
  The dev-only (`phoenix_live_reload`, `file_system`) and test-only
  (`lazy_html`, `fine`, `cc_precompiler`, `elixir_make`) packages of the
  template are left out: prod never loads them. A bump of the generator is a
  reviewed change, like `@phx_new` in `Compatibility.ConfigVariants`.

  A world is stored as the toolchain build variant `world_<name>`
  (`variants/0`). The portal sends the members to the worker in `NCC_INPUT`,
  so the worker image needs no copy of this list.
  """

  @worlds [
    {"phx", {"phx_new", @phx_new}, ~w(
       bandit db_connection decimal dns_cluster ecto ecto_sql esbuild expo finch gettext hpax idna
       jason mime mint nimble_options nimble_pool phoenix phoenix_ecto phoenix_html
       phoenix_live_dashboard phoenix_live_view phoenix_pubsub phoenix_template plug plug_crypto
       postgrex req swoosh tailwind telemetry telemetry_metrics telemetry_poller thousand_island
       websock websock_adapter
     )}
  ]

  @names Enum.map(@worlds, &elem(&1, 0))
  @variants Enum.map(@names, &String.to_atom("world_" <> &1))
  @by_variant Map.new(@names, &{"world_" <> &1, &1})

  @doc "The world names, in rank order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The toolchain build variants of the worlds, `:world_<name>`, in rank order."
  @spec variants() :: [atom()]
  def variants, do: @variants

  @doc "The sorted member package names of world `name`."
  @spec members(term()) :: {:ok, [String.t()]} | :error
  def members(name) do
    case List.keyfind(@worlds, name, 0) do
      {^name, _generator, members} -> {:ok, Enum.sort(members)}
      nil -> :error
    end
  end

  @doc "The generator and its version that world `name`'s members are taken from."
  @spec generator(term()) :: {:ok, {String.t(), String.t()}} | :error
  def generator(name) do
    case List.keyfind(@worlds, name, 0) do
      {^name, generator, _members} -> {:ok, generator}
      nil -> :error
    end
  end

  @doc "The toolchain build variant of world `name`."
  @spec variant(term()) :: {:ok, atom()} | :error
  def variant(name) do
    case Enum.find_index(@names, &(&1 == name)) do
      nil -> :error
      index -> {:ok, Enum.at(@variants, index)}
    end
  end

  @doc "The world of a toolchain build variant, as an atom or its text."
  @spec world(term()) :: {:ok, String.t()} | :error
  def world(variant) when is_atom(variant) and not is_nil(variant),
    do: world(Atom.to_string(variant))

  def world(variant) when is_binary(variant), do: Map.fetch(@by_variant, variant)
  def world(_variant), do: :error
end
