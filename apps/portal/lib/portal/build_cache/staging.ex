defmodule Portal.BuildCache.Staging do
  @moduledoc """
  Names for in-flight build cache entries, shared by `Portal.BuildCache.Promotion`
  (its host-side copy), `Portal.BuildCache.L2` (a download being extracted)
  and `Portal.Workers.Sweep` (which prunes what a crash left behind).

  A staging name is `<dest>.tmp.<host>.<hex>`, and the tarball a download
  is extracted from sits beside it as `<dest>.tmp.<host>.<hex>.tar.gz`. The
  host is in the name so a Sweep on one host never removes another host's
  in-flight staging when the cache root is shared, and so the `.tmp.<hex>`
  names written before the L2 work are still recognised (as having no host).
  """

  @pattern ~r/\.tmp\.(?:([A-Za-z0-9-]+)\.)?([0-9a-f]+)(\.tar\.gz)?\z/

  @doc "A fresh staging name beside `dest`."
  @spec name(Path.t()) :: Path.t()
  def name(dest),
    do:
      dest <>
        ".tmp." <> host() <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "This node's hostname, restricted to `[A-Za-z0-9-]`, at most 63 characters, never empty."
  @spec host() :: String.t()
  def host do
    case :inet.gethostname() do
      {:ok, name} -> name |> to_string() |> sanitize_host()
      _ -> "host"
    end
  end

  @doc false
  @spec sanitize_host(String.t()) :: String.t()
  def sanitize_host(name) do
    case name |> String.replace(~r/[^A-Za-z0-9-]/, "-") |> String.slice(0, 63) do
      "" -> "host"
      safe -> safe
    end
  end

  @doc "The host and kind of a staging name, or `:error` for any other name."
  @spec parse(String.t()) :: {:ok, %{host: String.t() | nil, download?: boolean()}} | :error
  def parse(name) do
    case Regex.run(@pattern, name) do
      [_, "", _hex] -> {:ok, %{host: nil, download?: false}}
      [_, "", _hex, _tar] -> {:ok, %{host: nil, download?: true}}
      [_, host, _hex] -> {:ok, %{host: host, download?: false}}
      [_, host, _hex, _tar] -> {:ok, %{host: host, download?: true}}
      nil -> :error
    end
  end

  @doc "Whether a staging name was written by `host` (or before hosts were recorded)."
  @spec ours?(String.t(), String.t()) :: boolean()
  def ours?(name, host) do
    case parse(name) do
      {:ok, %{host: nil}} -> true
      {:ok, %{host: ^host}} -> true
      _ -> false
    end
  end
end
