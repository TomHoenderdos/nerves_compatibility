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

  The checksum lookup is `Portal.HexPm.release_checksum/2`, the one
  `Portal.BuildCache.Promotion` uses; `config :portal, Portal.HexCache,
  release_checksum: fun` replaces it in tests.
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

  def promote(%{"hex_cache" => %{} = report}, run_id, opts) when is_binary(run_id) do
    root = Keyword.get_lazy(opts, :hex_cache, &Builder.hex_cache/0)
    lookup = Keyword.get_lazy(opts, :release_checksum, &default_lookup/0)
    scratch = Keyword.get_lazy(opts, :scratch_root, &Builder.scratch_root/0)

    source =
      [scratch, Builder.safe_name(run_id), "work", "hex-home"]
      |> Path.join()
      |> Compatibility.HexCache.packages_dir()

    report["misses"]
    |> Compatibility.HexCache.promote(source, root, lookup)
    |> Map.put(:touched, Compatibility.HexCache.touch(report["hits"], root))
  end

  def promote(_result, _run_id, _opts),
    do: %{promoted: 0, refused: 0, skipped: 0, ignored: 0, touched: 0}

  defp default_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_checksum, &Portal.HexPm.release_checksum/2)
  end
end
