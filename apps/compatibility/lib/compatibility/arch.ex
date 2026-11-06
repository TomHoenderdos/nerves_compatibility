defmodule Compatibility.Arch do
  @moduledoc """
  CPU architectures in the vocabulary of `images.json` (`x86_64`,
  `aarch64`): the keys of the worker image's per-architecture digests and of
  the agent releases, the architecture a remote builder claims for, and the
  one a run records (`Portal.Catalog.Run`).
  """

  @supported ["x86_64", "aarch64"]
  @aliases %{"amd64" => "x86_64", "arm64" => "aarch64"}

  @doc "The architectures CI publishes a worker image and an agent release for."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @spec supported?(term()) :: boolean()
  def supported?(arch), do: arch in @supported

  @doc """
  The architecture an Erlang system architecture string (a target triple
  such as `aarch64-unknown-linux-gnu`) names: its first component, with
  `amd64`/`arm64` spelled `x86_64`/`aarch64`. An architecture without a
  worker image keeps its own name (`armv7l`), which `supported?/1` refuses.
  """
  @spec normalize(charlist() | String.t()) :: String.t()
  def normalize(system_architecture) do
    arch =
      system_architecture
      |> to_string()
      |> String.split("-", parts: 2)
      |> hd()

    Map.get(@aliases, arch, arch)
  end

  @doc "This VM's architecture, `normalize/1`d."
  @spec current() :: String.t()
  def current, do: normalize(:erlang.system_info(:system_architecture))
end
