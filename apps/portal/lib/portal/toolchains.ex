defmodule Portal.Toolchains do
  @moduledoc """
  The Elixir/OTP toolchains the portal builds packages on, each with the
  worker image that carries it.

  A toolchain is written `"<elixir major.minor>/<otp major>"`, e.g.
  `"1.19/28"`. The images are built by `make build-toolchains` (the Makefile's
  `TOOLCHAIN_IMAGES`) beside the main `ncc-worker:local`, which is the 1.20/29
  one. Configured under `config :portal, Portal.Toolchains`; `config/runtime.exs`
  replaces `images` from `NCC_TOOLCHAINS` (see `parse/1`).

  `builder_version/0` names the build recipe. Bumping it makes every
  toolchain build stale, so the sweep rebuilds them.
  """

  alias Compatibility.ConfigVariants

  @toolchain ~r/^\d+\.\d+\/\d+$/

  @type image :: %{toolchain: String.t(), image: String.t()}

  @doc "The configured toolchains and their images, in configured order."
  @spec images() :: [image()]
  def images, do: Keyword.fetch!(config(), :images)

  @doc "The current toolchain build recipe version."
  @spec builder_version() :: pos_integer()
  def builder_version, do: Keyword.fetch!(config(), :builder_version)

  @doc "How many toolchain builds one `Portal.Workers.ToolchainSweep` enqueues, at most."
  @spec max_per_run() :: pos_integer()
  def max_per_run, do: Keyword.get(config(), :max_per_run, 300)

  @doc """
  The named config variants the sweep builds (`Compatibility.ConfigVariants`),
  in pinned order: every one unless `config :portal, Portal.Toolchains,
  config_variants:` lists a subset (`NCC_CONFIG_VARIANTS`, `parse_config_variants/1`).
  Builds already made of a variant left out stay served.
  """
  @spec config_variants() :: [String.t()]
  def config_variants do
    case Keyword.get(config(), :config_variants, :all) do
      :all -> ConfigVariants.names()
      list when is_list(list) -> Enum.filter(ConfigVariants.names(), &(&1 in list))
    end
  end

  @doc "Parses `NCC_CONFIG_VARIANTS`: `all`, `none`, or comma-separated names. Raises on an unknown name."
  @spec parse_config_variants(String.t()) :: :all | [String.t()]
  def parse_config_variants(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ["", "all"] ->
        :all

      "none" ->
        []

      list ->
        list |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.map(&known!/1)
    end
  end

  defp known!(name) do
    if name in ConfigVariants.names(),
      do: name,
      else: raise(ArgumentError, "NCC_CONFIG_VARIANTS lists an unknown variant: #{inspect(name)}")
  end

  @doc """
  The toolchain string for the Elixir and OTP versions a build reports, e.g.
  `"1.19/28"` for Elixir `"1.19.1"` on OTP `"28"`. Only the Elixir
  major.minor and the OTP major count, as in the configured toolchains. Nil
  when either is not a version string.
  """
  @spec from_versions(term(), term()) :: String.t() | nil
  def from_versions(elixir, otp) when is_binary(elixir) and is_binary(otp) do
    with [major, minor | _] <- String.split(elixir, "."),
         [otp_major | _] <- String.split(otp, "."),
         toolchain = "#{major}.#{minor}/#{otp_major}",
         true <- Regex.match?(@toolchain, toolchain) do
      toolchain
    else
      _ -> nil
    end
  end

  def from_versions(_elixir, _otp), do: nil

  @doc """
  Parse `NCC_TOOLCHAINS`: comma-separated `toolchain=image` pairs, e.g.
  `"1.20/29=ncc-worker:local,1.19/28=ncc-worker:elixir-1.19-otp-28"`.

  Raises `ArgumentError` naming the offending pair when a pair has no `=`, an
  empty image, a toolchain not shaped like `1.19/28`, or repeats a toolchain,
  and when the list is empty. It runs at boot, so a typo stops the release
  rather than quietly building on fewer toolchains.
  """
  @spec parse(String.t()) :: [image()]
  def parse(value) when is_binary(value) do
    images =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_pair/1)

    if images == [] do
      raise ArgumentError, "NCC_TOOLCHAINS lists no toolchains, got: #{inspect(value)}"
    end

    images
    |> Enum.frequencies_by(& &1.toolchain)
    |> Enum.find(fn {_toolchain, count} -> count > 1 end)
    |> case do
      nil -> images
      {toolchain, _} -> raise ArgumentError, "NCC_TOOLCHAINS lists #{toolchain} twice"
    end
  end

  defp parse_pair(pair) do
    with [toolchain, image] <- String.split(pair, "=", parts: 2),
         toolchain = String.trim(toolchain),
         image = String.trim(image),
         true <- Regex.match?(@toolchain, toolchain),
         true <- image != "" do
      %{toolchain: toolchain, image: image}
    else
      _ ->
        raise ArgumentError,
              "NCC_TOOLCHAINS entries must look like `1.19/28=image`, got: #{inspect(pair)}"
    end
  end

  defp config, do: Application.fetch_env!(:portal, __MODULE__)
end
