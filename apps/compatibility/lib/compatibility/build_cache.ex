defmodule Compatibility.BuildCache do
  @moduledoc """
  Names in the shared L2 build cache, for the two readers of it: the portal's
  own prefetch (`Portal.BuildCache.L2`) and a remote builder's
  (`NccAgent.BuildCache`), which reads the same objects through presigned URLs
  the portal hands it.

  An object is `<slug>/<key>.tar.gz`: the slug is the worker image digest made
  safe for a directory name (`sha256_<64 hex>`), the key the worker's 64-hex
  cache key, the body `Compatibility.BuildCache.Tarball`'s gzip tarball. Both
  are validated here before either becomes part of a local path.
  """

  @shareable_slug ~r/\Asha256_[0-9a-f]{64}\z/
  @zero_slug "sha256_" <> String.duplicate("0", 64)
  @key ~r/\A[0-9a-f]{64}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @budget_bytes 2 * 1024 * 1024 * 1024
  @extracted_budget_bytes 4 * 1024 * 1024 * 1024
  @budget_ms 5 * 60 * 1000

  @doc """
  One build's prefetch budget, the same for a home host and a remote builder:
  at most 2 GiB downloaded, 4 GiB extracted and 5 minutes, listing included.
  """
  @spec prefetch_budget() :: %{
          bytes: pos_integer(),
          extracted_bytes: pos_integer(),
          ms: pos_integer()
        }
  def prefetch_budget,
    do: %{bytes: @budget_bytes, extracted_bytes: @extracted_budget_bytes, ms: @budget_ms}

  @doc "Whether `slug` names one image by content: `sha256_<64 hex>`, not all zeros."
  @spec shareable_slug?(term()) :: boolean()
  def shareable_slug?(slug) when is_binary(slug),
    do: slug != @zero_slug and Regex.match?(@shareable_slug, slug)

  def shareable_slug?(_slug), do: false

  @doc "Whether `key` is a cache key as the worker writes it: 64 lowercase hex."
  @spec key?(term()) :: boolean()
  def key?(key) when is_binary(key), do: Regex.match?(@key, key)
  def key?(_key), do: false

  @doc "Whether `sha` is a lowercase hex SHA-256."
  @spec sha256?(term()) :: boolean()
  def sha256?(sha) when is_binary(sha), do: Regex.match?(@sha256, sha)
  def sha256?(_sha), do: false

  @spec object_key(String.t(), String.t()) :: String.t()
  def object_key(slug, key), do: slug <> "/" <> key <> ".tar.gz"

  @doc """
  The key of an object name under `prefix` (`"<slug>/"`), or nil for any
  name that is not `<prefix><64 hex>.tar.gz`.
  """
  @spec object_hex(String.t(), String.t()) :: String.t() | nil
  def object_hex(object, prefix) when is_binary(object) do
    with ^prefix <> rest <- object,
         [hex, ""] <- String.split(rest, ".tar.gz", parts: 2),
         true <- key?(hex) do
      hex
    else
      _ -> nil
    end
  end

  def object_hex(_object, _prefix), do: nil
end
