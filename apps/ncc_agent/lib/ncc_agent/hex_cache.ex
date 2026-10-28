defmodule NccAgent.HexCache do
  @moduledoc """
  The slot's shared Hex cache, mounted read-only at `/hex-cache`
  (`Compatibility.Builder.Argv`), and its one writer.

  The worker seeds a per-run `HEX_HOME` from the cache's tarballs, never its
  registry cache or `hex.config` (`NccWorker.HexCache`), and reports what it
  had to download. After a run the portal completed as `done`, `promote/3`
  moves those downloads in, each only once its own bytes hash to the
  checksum Hex.pm publishes for the release (`Compatibility.HexCache`), as
  the local host does (`Portal.HexCache`).

  `prepare/1` still removes `hex.config` and `cache.ets` before every run.
  Builds from before the read-only mount wrote the cache, and could have
  left either for a later build to trust; the worker no longer reads them,
  so the scrub only keeps an older worker image safe. The dir is per slot
  (`NccAgent.Config.path/2`).
  """

  require Logger

  alias NccAgent.Config

  @scrubbed ~w(hex.config cache.ets)
  @api_url "https://hex.pm/api"

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

    for name <- @scrubbed, path = Path.join(dir, name), match?({:ok, _}, File.lstat(path)) do
      Logger.info("hex cache: removing #{name} left by an earlier build")
      File.rm_rf(path)
    end

    :ok
  end

  @doc """
  Promotes the Hex tarballs the run in `work_dir` downloaded, as its
  `result.json` (in `out_dir`) lists them, into the slot's cache, and
  refreshes the cached tarballs it used. Best effort: a tarball not promoted
  is only fetched again by a later build. `config :ncc_agent,
  NccAgent.HexCache, release_checksum: fun` replaces the Hex.pm lookup in
  tests.
  """
  @spec promote(Config.t(), Path.t(), Path.t()) :: :ok
  # `out_dir` and `work_dir` are the run's own scratch binds; result.json was
  # checked as a regular file within its cap before the run completed.
  # sobelow_skip ["Traversal.FileModule"]
  def promote(config, work_dir, out_dir) do
    with {:ok, json} <- File.read(Path.join(out_dir, "result.json")),
         {:ok, %{"hex_cache" => %{} = report}} <- Jason.decode(json) do
      root = Config.path(config, :hex_cache)
      source = Compatibility.HexCache.packages_dir(Path.join(work_dir, "hex-home"))

      counts = Compatibility.HexCache.promote(report["misses"], source, root, lookup())
      _ = Compatibility.HexCache.touch(report["hits"], root)

      if counts.promoted + counts.refused > 0,
        do:
          Logger.info(
            "hex cache: promoted #{counts.promoted}, refused #{counts.refused}, " <>
              "skipped #{counts.skipped}"
          )
    end

    :ok
  rescue
    e -> Logger.warning("hex cache promotion crashed: #{Exception.message(e)}")
  end

  defp lookup do
    :ncc_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_checksum, &release_checksum/2)
  end

  # Each part is one path segment, so nothing in it may add another. Fails
  # fast: the slot stays busy until promotion ends.
  defp release_checksum(name, version) do
    url =
      "#{@api_url}/packages/#{URI.encode(name, &URI.char_unreserved?/1)}" <>
        "/releases/#{URI.encode(version, &URI.char_unreserved?/1)}"

    case Req.get(url, retry: false, receive_timeout: 5_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: %{"checksum" => checksum}}} when is_binary(checksum) ->
        {:ok, checksum}

      {:ok, %{status: 404}} ->
        {:error, :unknown_release}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
