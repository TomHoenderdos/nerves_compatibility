defmodule Compatibility.HostTriple do
  @moduledoc """
  The target triple a host-native build is made for and matched on
  (`docs/superpowers` design addendum for #85, `PRECOMPILED_API.md`): the
  CPU architecture (`Compatibility.Arch`, x86_64 or aarch64) of a glibc
  Linux system, spelled `x86_64-linux-gnu` or `aarch64-linux-gnu`.

  `normalize/1` reads it from an Erlang system architecture
  (`:erlang.system_info(:system_architecture)`), whose vendor field differs
  between distributions (`x86_64-pc-linux-gnu`, `x86_64-redhat-linux-gnu`,
  `aarch64-unknown-linux-gnu`) and is dropped. Everything else is no triple:
  musl (`-linux-musl`), darwin, other Linux ABIs (`gnueabihf`, `gnux32`) and
  other architectures. The worker records its own VM's triple, and a client
  compares its own; both sides use this one function's rules.
  """

  alias Compatibility.Arch

  @machines %{"x86_64" => :x86_64, "aarch64" => :aarch64}

  @doc "The triples a host-native build may name."
  @spec all() :: [String.t()]
  def all, do: Enum.map(Arch.supported(), &(&1 <> "-linux-gnu"))

  @spec valid?(term()) :: boolean()
  def valid?(triple), do: triple in all()

  @doc "The triple an Erlang system architecture names, or `:error`."
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(system_architecture) when is_list(system_architecture) do
    normalize(List.to_string(system_architecture))
  rescue
    _ -> :error
  end

  def normalize(system_architecture) when is_binary(system_architecture) do
    parts = String.split(system_architecture, "-")
    arch = Arch.normalize(system_architecture)

    if length(parts) in 3..4 and Enum.take(parts, -2) == ["linux", "gnu"] and
         Arch.supported?(arch),
       do: {:ok, arch <> "-linux-gnu"},
       else: :error
  end

  def normalize(_system_architecture), do: :error

  @doc "This VM's triple."
  @spec current() :: {:ok, String.t()} | :error
  def current, do: normalize(:erlang.system_info(:system_architecture))

  @doc "The ELF machine (`Compatibility.Elf`) a triple's files have."
  @spec elf_machine(term()) :: {:ok, :x86_64 | :aarch64} | :error
  def elf_machine(triple) do
    with true <- valid?(triple),
         [arch | _] <- String.split(triple, "-") do
      Map.fetch(@machines, arch)
    else
      _ -> :error
    end
  end
end
