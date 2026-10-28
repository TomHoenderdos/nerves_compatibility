defmodule Portal.HexCache do
  @moduledoc """
  The host side of the shared Hex cache (`Portal.Builder.hex_cache/0`).

  Builds mount the cache read-only and fetch what it lacks into their own
  per-run `HEX_HOME` at `work/hex-home` (`NccWorker.HexCache`), reporting
  those downloads, and the cached tarballs their lock used, as
  `hex_cache` in `result.json`. After the container has exited and before
  ingest, `Portal.Workers.Build` calls `promote/3`: each download goes into
  the cache only once its own bytes hash to the outer checksum Hex.pm
  publishes for the release (`Compatibility.HexCache.promote/5`, which lists
  every check), and each used tarball's times are refreshed so
  `Portal.Workers.Sweep` keeps evicting by last use. The checksum the worker
  reported and the path it named are never used: the source path is rebuilt
  from the run id and the validated name and version.

  The checksum is the one the signed registry on `repo.hex.pm` lists
  (`Portal.HexDeps.outer_checksum/3`), which is what Hex itself checks a
  tarball against. It comes from the CDN, is cached per package for an hour
  and spends none of the hex.pm API quota `Portal.BuildCache.Promotion`
  uses; a rate limit or an outage skips the rest of the promotion. Each
  lookup fails fast (`Compatibility.HexCache.lookup_timeout_ms/0`).
  `config :portal, Portal.HexCache, release_checksum: fun` replaces it in
  tests.
  """

  alias Portal.Builder

  @type counts :: %{
          promoted: non_neg_integer(),
          refused: non_neg_integer(),
          skipped: non_neg_integer(),
          ignored: non_neg_integer(),
          touched: non_neg_integer()
        }

  @doc """
  Promotes the downloads `result` reports for `run_id` into the Hex cache and
  refreshes the tarballs it used. Options: `:release_checksum` (the lookup),
  `:hex_cache` (the cache root) and `:scratch_root`, each defaulting to the
  configured one.
  """
  @spec promote(map() | nil, String.t(), keyword()) :: counts()
  def promote(result, run_id, opts \\ [])

  def promote(%{"hex_cache" => %{} = report} = result, run_id, opts) when is_binary(run_id) do
    root = Keyword.get_lazy(opts, :hex_cache, &Builder.hex_cache/0)
    lookup = Keyword.get_lazy(opts, :release_checksum, &default_lookup/0)
    scratch = Keyword.get_lazy(opts, :scratch_root, &Builder.scratch_root/0)

    work = Path.join([scratch, Builder.safe_name(run_id), "work"])
    source = work |> Path.join("hex-home") |> Compatibility.HexCache.packages_dir()
    locked = Compatibility.HexCache.locked_pairs(result)

    report["misses"]
    |> Compatibility.HexCache.promote(source, root, lookup, trusted: work)
    |> Map.put(:touched, Compatibility.HexCache.touch(report["hits"], root, locked))
  end

  def promote(_result, _run_id, _opts),
    do: %{promoted: 0, refused: 0, skipped: 0, ignored: 0, touched: 0}

  defp default_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_checksum, &registry_checksum/2)
  end

  # Connect plus receive stay within `Compatibility.HexCache.lookup_timeout_ms/0`.
  defp registry_checksum(name, version) do
    half = div(Compatibility.HexCache.lookup_timeout_ms(), 2)

    Portal.HexDeps.outer_checksum(name, version,
      retry: false,
      receive_timeout: half,
      connect_options: [timeout: half]
    )
  end
end
