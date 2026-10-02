defmodule NccWorker.Systems do
  @moduledoc """
  The Nerves systems this worker knows how to build against.

  One list serving two callers, and they have to agree. `NccWorker.Project`
  needs the `target` names to pass as `--target` flags to `mix nerves.new`,
  because that is what decides which `nerves_system_*` deps land in the
  generated `mix.exs`. `NccWorker.Worker` needs the `name` values to set
  `MIX_TARGET` and to key results by. A target the project was never generated
  for does not fail loudly — it fails every single build for that system with a
  missing dependency, which reads like the package being broken. Keeping both
  halves in one module is what prevents that drift.

  This is also why `mix nerves.new` is called with explicit targets rather than
  bare. Bare, it emits nerves_bootstrap's `@default_targets`, which is eleven
  systems we mostly do not build — and which notably excludes `trellis`.

  ## Image coupling

  Naming targets explicitly couples this list to the `nerves_bootstrap` archive
  baked into the worker image: `mix nerves.new` rejects a target it does not
  know with `** (Mix) Unknown target`, which fails `Project.create/3` and so
  fails the whole run with exit 10 for *every* package, not just that target.

  `trellis` requires **nerves_bootstrap >= 1.17.0**. The Dockerfile installs the
  archive unpinned, so an image's capabilities depend on when it was built —
  a stale image is the failure mode to check first if every build suddenly
  starts erroring. Loud beats silent here: the old bare invocation would have
  quietly produced no trellis results at all.
  """

  @type t :: %{name: String.t(), target: String.t()}

  # Every system we can build. Order is the order results come back in.
  @all [
    %{name: "nerves_system_bbb", target: "bbb"},
    %{name: "nerves_system_grisp2", target: "grisp2"},
    %{name: "nerves_system_mangopi_mq_pro", target: "mangopi_mq_pro"},
    %{name: "nerves_system_qemu_aarch64", target: "qemu_aarch64"},
    %{name: "nerves_system_rpi0", target: "rpi0"},
    %{name: "nerves_system_rpi4", target: "rpi4"},
    %{name: "nerves_system_rpi5", target: "rpi5"},
    %{name: "nerves_system_trellis", target: "trellis"},
    %{name: "nerves_system_x86_64", target: "x86_64"}
  ]

  # What every build runs when the caller does not ask for something specific.
  #
  # Originally one system per ABI, so a precompiled-NIF gap showed up exactly
  # once: rpi4 for arm64, x86_64, mangopi_mq_pro for riscv64 and trellis for
  # arm32. The set now also covers the boards people actually deploy -- bbb,
  # rpi0, rpi5 and qemu_aarch64 -- so a board-specific failure is visible too.
  # rpi0 is the one addition that brings a new ABI: armv6, which precompiled
  # artifacts skip most often. The others mostly repeat an architecture already
  # covered, and each costs about one more full build per package.
  #
  # grisp2 stays out: 0.18.0 requires `nerves ~> 1.11`, and since every
  # default target's system lands in the same generated mix.exs, it would fail
  # dependency resolution for the whole run on Nerves 2, not just its own
  # target. Its main branch already accepts 2.0; add it once that is released.
  #
  # trellis is also the Nerves Starter Kit board, so it is the configuration
  # newcomers actually hit first.
  @default [
    "nerves_system_bbb",
    "nerves_system_mangopi_mq_pro",
    "nerves_system_qemu_aarch64",
    "nerves_system_rpi0",
    "nerves_system_rpi4",
    "nerves_system_rpi5",
    "nerves_system_trellis",
    "nerves_system_x86_64"
  ]

  @doc "Every system this worker can build, in result order."
  @spec all() :: [t()]
  def all, do: @all

  @doc "The systems built when no filter is supplied."
  @spec default() :: [t()]
  def default, do: Enum.filter(@all, &(&1.name in @default))

  @doc """
  Resolves a caller-supplied filter to a system list.

  A `nil` filter means "use the defaults". A list filters `all/0` by system
  package name, preserving `all/0`'s order so results stay comparable across
  runs regardless of how the caller ordered its request. Names that match
  nothing are dropped.
  """
  @spec select([String.t()] | nil) :: [t()]
  def select(nil), do: default()

  def select(filter) when is_list(filter),
    do: Enum.filter(@all, &(&1.name in filter))

  @doc "Just the `--target` names for `mix nerves.new`."
  @spec targets([t()]) :: [String.t()]
  def targets(systems), do: Enum.map(systems, & &1.target)
end
