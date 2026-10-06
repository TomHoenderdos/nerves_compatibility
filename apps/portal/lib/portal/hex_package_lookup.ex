defmodule Portal.HexPackageLookup do
  @moduledoc """
  Whether a name is a package on hex.pm, for the anonymous request form.

  A name the catalog already has is one we have built, so it exists and costs
  nothing to confirm. Anything else is asked of the `repo.hex.pm` CDN through
  `Portal.HexDeps` rather than of the hex.pm API: Hex's team asked the project
  to poll the repository, and `Portal.HexDeps` already caches its answers for an
  hour, so a name submitted twice is fetched once.
  """

  import Ecto.Query, only: [from: 2]

  # Someone is waiting on the form. One slow CDN answer must not hold their
  # request through Req's retry schedule or `Portal.HexDeps`' 30 s default.
  @request_opts [retry: false, receive_timeout: 5_000]

  @doc """
  `{:error, :hex_api_unavailable}` is "we could not find out", which is not the
  same answer as `{:ok, false}`: a caller refusing a name on it would tell
  someone their real package does not exist because the CDN hiccuped.

  `opts` pass through to `Portal.HexDeps.releases/2`; they exist for tests.
  """
  @spec package_exists?(String.t(), keyword()) ::
          {:ok, boolean()} | {:error, :hex_api_unavailable}
  def package_exists?(name, opts \\ []) when is_binary(name) do
    if catalogued?(name), do: {:ok, true}, else: ask_cdn(name, opts)
  end

  defp catalogued?(name) do
    Portal.Repo.exists?(from(p in "catalog_packages", where: p.name == ^name))
  end

  defp ask_cdn(name, opts) do
    case Portal.HexDeps.releases(name, Keyword.merge(opts, @request_opts)) do
      {:ok, _releases} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _unavailable_or_undecodable} -> {:error, :hex_api_unavailable}
    end
  end
end
