defmodule NccAgent.HexCache do
  @moduledoc """
  The shared Hex cache a build mounts read-write at `/hex-cache`, scrubbed
  between runs.

  Every build container (the local host's too) mounts the cache read-write,
  and the worker seeds each build's private `HEX_HOME` from it: the
  registry snapshot `cache.ets`, the tarballs under `packages/`, and
  `hex.config` when present. A package's build could therefore leave a
  `hex.config` naming its own repo and public key, or a `cache.ets` with its
  own checksums, for every later build on this builder to trust. Before each
  run the agent removes those two from the shared dir: the next build fetches
  a registry that Hex verifies against its built-in key, and a planted
  tarball then fails its checksum. `packages/` stays, which is the cache.
  A proper fix (a read-only mount with host-side promotion, as the build
  cache has) belongs to the worker and the local host alike.
  """

  require Logger

  alias NccAgent.Config

  @scrubbed ~w(hex.config cache.ets)

  @doc "Makes the cache dir a real directory and removes what a build must not hand the next."
  @spec prepare(Config.t()) :: :ok
  # The cache dir is the agent's own, under its data dir.
  # sobelow_skip ["Traversal.FileModule"]
  def prepare(config) do
    dir = Config.path(config, :hex_cache)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        File.mkdir_p!(dir)

      other ->
        Logger.error("#{dir} is not a directory (#{inspect(other)}): replaced with an empty one")
        File.rm_rf(dir)
        File.mkdir_p!(dir)
    end

    for name <- @scrubbed, path = Path.join(dir, name), File.exists?(path, [:raw]) do
      Logger.info("hex cache: removing #{name} left by an earlier build")
      File.rm_rf(path)
    end

    :ok
  end
end
