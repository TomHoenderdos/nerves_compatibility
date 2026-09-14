defmodule Portal.HexRegistry do
  @moduledoc """
  Reads the hex.pm package registry from `repo.hex.pm`.

  ## Why the repository and not the API

  The obvious way to notice new releases is `GET /api/packages?sort=updated_at`,
  and that is what this started as. Hex's own team asked us not to: the API is
  served from their application, while `repo.hex.pm` sits behind a CDN and
  exists precisely to be polled. Two requests here replace a paged walk of the
  API and cost hex.pm nothing.

  The protocol is [registry v2][spec]. Each resource is a gzipped, signed
  protobuf; `:hex_core` verifies the signature against hex.pm's public key and
  decodes it, so nothing here parses protobuf by hand.

  [spec]: https://github.com/hexpm/specifications/blob/main/registry-v2.md

  ## Why both resources

  Neither one answers the question on its own:

    * `/names` gives every package name and the timestamp it last changed --
      which is how we order work, but it carries no versions.
    * `/versions` gives every released version of every package -- which is how
      we learn the latest one, but it carries no timestamps.

  Joining them yields the whole registry in the shape the update check wants.
  About 360 KB each at the time of writing, for ~22,000 packages, with a
  one-hour `cache-control` that matches the hourly schedule.

  ## Whole registry, not a window

  Because one request describes every package, there is no cutoff to choose and
  no state to keep. A caller diffs the registry against its own records and sees
  everything that has drifted, however long ago it moved -- not just what
  changed since some watermark. That is what lets `Portal.Workers.UpdateCheck`
  be stateless without silently skipping releases.
  """

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"

  @typedoc "One registry package: the newest version published, and when it last changed."
  @type entry :: %{
          name: String.t(),
          latest_version: String.t(),
          updated_at: DateTime.t() | nil
        }

  @doc """
  Fetch and decode the whole registry.

  Both options exist so the decode and join can be exercised against a locally
  built registry. Neither is passed by anything in the application, and the
  defaults are the real client and hex.pm's own key:

    * `:client` - HTTP client module exposing `get/2` (default `Req`).
    * `:public_key` - key the signature is checked against (default hex.pm's).
  """
  @spec snapshot(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def snapshot(opts \\ []) do
    client = Keyword.get(opts, :client, Req)
    key = Keyword.get(opts, :public_key, public_key())

    with {:ok, names_body} <- fetch(client, "/names"),
         {:ok, versions_body} <- fetch(client, "/versions"),
         {:ok, names} <- unpack(:names, names_body, key),
         {:ok, versions} <- unpack(:versions, versions_body, key) do
      {:ok, join(names, versions)}
    end
  end

  # `compressed: false` and `decode_body: false` are both load-bearing. A
  # registry resource is gzip *content* that `:hex_core` expects to gunzip
  # itself; if Req advertises gzip and the CDN answers with a
  # `content-encoding` header, Req unwraps it first and the decode below fails
  # on a body that is already valid protobuf.
  defp fetch(client, path) do
    case client.get("#{@repo_url}#{path}",
           compressed: false,
           decode_body: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("Hex registry #{path} failed: HTTP #{status}")
        {:error, :hex_registry_unavailable}

      {:error, reason} ->
        Logger.warning("Hex registry #{path} failed: #{inspect(reason)}")
        {:error, :hex_registry_unavailable}
    end
  end

  # Wrapped in try/rescue because the failure is not uniform: a bad signature
  # comes back as `{:error, :unverified}`, but a body that is not valid gzip
  # raises out of `:zlib` instead. A truncated CDN response should defer the
  # check to the next tick, not crash the worker.
  defp unpack(resource, body, key) do
    unpacker =
      case resource do
        :names -> &:hex_registry.unpack_names/3
        :versions -> &:hex_registry.unpack_versions/3
      end

    case unpacker.(body, @repository, key) do
      {:ok, %{packages: packages}} -> {:ok, packages}
      {:error, reason} -> registry_error(resource, reason)
    end
  rescue
    error -> registry_error(resource, error)
  end

  defp registry_error(resource, reason) do
    Logger.warning("Hex registry /#{resource} did not decode: #{inspect(reason)}")
    {:error, :hex_registry_undecodable}
  end

  defp public_key, do: :hex_core.default_config()[:repo_public_key]

  defp join(names, versions) do
    updated = Map.new(names, &{&1.name, timestamp(&1)})

    Enum.flat_map(versions, fn package ->
      case latest(package) do
        nil ->
          []

        version ->
          [
            %{
              name: package.name,
              latest_version: version,
              updated_at: Map.get(updated, package.name)
            }
          ]
      end
    end)
  end

  # `/versions` lists a package's releases in ascending semver order -- verified
  # against the live registry, where none of ~22,000 packages was out of order --
  # so the last entry is the newest.
  #
  # Retired versions are left in. They are still published releases, and hex's
  # own `latest_version` counts them, so dropping them here would make our
  # comparison disagree with the value we store. A retired version we do pick up
  # still resolves through `Portal.HexPm` before anything is built.
  defp latest(%{versions: versions}) when is_list(versions), do: List.last(versions)
  defp latest(_package), do: nil

  # `updated_at` is `optional` in the protobuf. Every package carries one today,
  # but a missing one must not be invented: callers order by this field, and a
  # fabricated epoch timestamp would jump the package to the front of the queue.
  # `nil` says "unknown" and lets the caller decide.
  defp timestamp(%{updated_at: %{seconds: seconds}}) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_package), do: nil
end
