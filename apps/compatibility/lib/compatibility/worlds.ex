defmodule Compatibility.Worlds do
  @phx_new "1.8.16"
  @nerves_bootstrap "1.17.4"

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

  ## The firmware world

  `nerves` is kept apart (`firmware_names/0`): it is the prod package set,
  per device target, of a default `mix nerves.new` app from nerves_bootstrap
  #{@nerves_bootstrap} (nerves_pack on, Nerves 1.x), less the target's
  system, `nerves_system_br` and toolchain. Every device target of the
  template has the same set. A firmware run builds it per passing target
  beside the build with and without the optional deps
  (`NccWorker.WorldTargets`) and publishes it as the firmware variant
  `world_nerves` (`firmware_variant/1`), never as a toolchain build:
  `names/0` and `variants/0` do not list it. jason and elixir_make are
  members because nerves 1.x depends on them; when Nerves 2 becomes the
  default, that is a reviewed bump of the generator and the list, as for
  `@phx_new`.
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

  @firmware_worlds [
    {"nerves", {"nerves_bootstrap", @nerves_bootstrap}, ~w(
       beam_notify circular_buffer elixir_make interactive_cmd jason logger_backends mdns_lite
       muontrap nerves nerves_discovery nerves_logging nerves_motd nerves_pack nerves_runtime
       nerves_ssh nerves_time nerves_uevent one_dhcpd property_table ring_logger shoehorn
       ssh_subsystem_fwup tablet toolshed uboot_env vintage_net vintage_net_direct
       vintage_net_ethernet vintage_net_wifi
     )}
  ]

  @names Enum.map(@worlds, &elem(&1, 0))
  @firmware_names Enum.map(@firmware_worlds, &elem(&1, 0))
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

  @doc "The firmware world names (`NccWorker.WorldTargets`), in rank order."
  @spec firmware_names() :: [String.t()]
  def firmware_names, do: @firmware_names

  @doc "The firmware variants, `world_<name>`, as `published_variants` names them."
  @spec firmware_variants() :: [String.t()]
  def firmware_variants, do: Enum.map(@firmware_names, &("world_" <> &1))

  @doc "The sorted member package names of firmware world `name`."
  @spec firmware_members(term()) :: {:ok, [String.t()]} | :error
  def firmware_members(name) do
    case List.keyfind(@firmware_worlds, name, 0) do
      {^name, _generator, members} -> {:ok, Enum.sort(members)}
      nil -> :error
    end
  end

  @doc "The generator and its version that firmware world `name`'s members are taken from."
  @spec firmware_generator(term()) :: {:ok, {String.t(), String.t()}} | :error
  def firmware_generator(name) do
    case List.keyfind(@firmware_worlds, name, 0) do
      {^name, generator, _members} -> {:ok, generator}
      nil -> :error
    end
  end

  @doc "The `published_variants` name of firmware world `name`, `\"world_<name>\"`."
  @spec firmware_variant(term()) :: {:ok, String.t()} | :error
  def firmware_variant(name) do
    if name in @firmware_names, do: {:ok, "world_" <> name}, else: :error
  end
end
