defmodule Portal.BuildCache.L2 do
  @moduledoc """
  The second, shared layer of the dependency build cache: an S3 bucket
  (Garage, on the tailnet) that every home build host writes after a
  promotion and reads before a build, so an entry one host compiled is
  restored on the others instead of being compiled again.

  Objects are named `<slug>/<key>.tar.gz` (`object_key/2`): the slug is the
  worker image digest (`Portal.Builder.cache_slug/1`), the key the worker's
  64-hex cache key, the body `Portal.BuildCache.L2.Tarball`'s gzip tarball.
  L2 is on only with a complete `Portal.BuildCache.L2.Config` and a local
  cache to restore into (`enabled?/0`).

  ## Writing

  `upload/5` runs on the host right after `Portal.BuildCache.Promotion` has
  renamed an entry into the local cache, and stores it with its SHA-256 in
  the `x-amz-meta-sha256` metadata. Nothing else writes the bucket.

  ## Reading: the slug listing, not a build plan

  The cache keys a build needs are computed inside the container, after
  `mix deps.get`, from the package's resolved dependency tree. The host
  cannot compute them without loading the package's `mix.exs`, which is the
  untrusted code the container exists to isolate, and the container cannot
  reach the bucket (the egress filter allows only public addresses). So
  `prefetch/3` does not fetch "the build's keys": before every build it lists
  `<slug>/` and downloads, newest first, every object whose key the local slug
  directory lacks. The local directory converges on the bucket over a few
  builds, and an entry another host uploaded is present locally for every
  later build. Hosts share only under the same slug, that is, only when they
  run the same worker image digest; a locally built image has its own slug
  and shares nothing.

  The budget is per build: at most 2 GiB and 5 minutes, and no single object
  over `Tarball.max_object_bytes/0`. An object over the remaining byte budget
  is skipped rather than ending the loop, so small entries behind a large one
  still arrive. A timeout or a transport error ends the loop for this build:
  the store is unwell, and the build should not wait on it once per object.
  Two builds on one node never fetch the same key at once (`Stats.claim/1`).

  ## Why a downloaded entry is trusted

  A local entry is trusted because Promotion checked it: the key recomputed,
  the outer checksum matched Hex, the tree walked on a host-private copy.
  The downloader cannot repeat any of that; it did not build the tree and
  cannot recompute its key. It trusts the bucket instead, and the bucket is
  trustworthy exactly as far as its writers are: only hosts holding the
  read-write key can PUT, and each of them runs Promotion before uploading.
  The integrity of L2 is the integrity of that key (`docs/BUILD_CACHE_L2.md`:
  read-write on the home hosts only, read-only for anything else).

  What the downloader still checks is what a faulty or hostile transport
  could change without the key. The tarball's SHA-256 must equal the
  uploader's metadata, and the object may not be larger than the listing
  said. `Tarball.unpack/3` screens the tar table before extracting anything
  (regular files and directories only, safe names, bounded size), recreates
  Mix's `priv`/`include` links only from a validated manifest, and walks the
  result with Promotion's own rules, so not even a wrong object can plant a
  symlink, hardlink, device, setuid file or escaping path in the slug. A
  refused object is marked bad on this node and not fetched again for 24
  hours. Extraction goes to a staging name beside the entry and is renamed
  into place only if the entry is still absent; an entry that appeared
  meanwhile (a local promotion) wins and the download is discarded.

  What a hostile bucket could still do is serve wrong beams under a
  well-formed key. That is the write-key compromise above, the same power a
  compromised home host has over its own local cache.

  ## Nothing here fails a build

  The cache is an optimisation. `upload/5` and `prefetch/3` never raise past
  their boundary; every failure is logged with the object name, counted in
  `Portal.BuildCache.L2.Stats`, and the build carries on with whatever the
  local cache holds.
  """
  require Logger
  alias Portal.BuildCache.L2.{Client, Config, Prefetch, Stats, Tarball}
  alias Portal.BuildCache.Staging

  @spec object_key(String.t(), String.t()) :: String.t()
  def object_key(slug, key), do: slug <> "/" <> key <> ".tar.gz"

  @doc "On only with a complete config and a local cache to restore into."
  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _}, Config.config()) and Portal.Builder.build_cache() != nil

  @spec status() :: map()
  def status do
    base = %{
      node: Staging.host(),
      endpoint: nil,
      bucket: nil,
      read_only?: false
    }

    {state, base} =
      case Config.config() do
        {:ok, cfg} ->
          {:on, %{base | endpoint: cfg.endpoint, bucket: cfg.bucket, read_only?: cfg.read_only?}}

        :off ->
          {:off, base}

        {:error, _} ->
          {:incomplete, base}
      end

    snap = Stats.snapshot()

    base
    |> Map.put(:state, state)
    |> Map.put(:last_upload, snap.last_upload)
    |> Map.put(:last_download, snap.last_download)
    |> Map.put(:counters, Map.drop(snap, [:last_upload, :last_download]))
  end

  @doc """
  Uploads one promoted entry, best effort: `{:ok, bytes}` with the tarball
  size, `:skipped` when L2 is off or read-only, `{:error, reason}` on any
  failure, never an exception. Logs its own outcome and records it in `Stats`.
  """
  @spec upload(Path.t(), String.t(), String.t(), String.t() | :any, keyword()) ::
          {:ok, non_neg_integer()} | :skipped | {:error, term()}
  def upload(entry_dir, slug, key, package, opts \\ []) do
    case Keyword.get_lazy(opts, :config, &active_config/0) do
      %Config{read_only?: false} = cfg -> do_upload(cfg, entry_dir, slug, key, package)
      _ -> :skipped
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp active_config do
    case Config.config() do
      {:ok, cfg} -> cfg
      _ -> nil
    end
  end

  # `entry_dir` is a promoted entry under the operator's cache root; the
  # tarball is staged beside it, inside the slug dir, and always removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_upload(cfg, entry_dir, slug, key, package) do
    object = object_key(slug, key)
    tar = Staging.name(entry_dir) <> ".tar.gz"

    result =
      try do
        with {:ok, %{sha256: sha, bytes: bytes}} <- Tarball.pack(entry_dir, tar, package),
             :ok <- Client.put(cfg, object, tar, sha) do
          {:ok, bytes}
        end
      after
        _ = File.rm(tar)
      end

    case result do
      {:ok, bytes} ->
        Stats.record(:upload_ok, bytes)
        Logger.info("Build cache L2 upload of #{object}: #{bytes} bytes")
        {:ok, bytes}

      {:error, reason} ->
        Stats.record(:upload_failed)

        Logger.warning(
          "Build cache L2 upload of #{object} failed: #{inspect(reason, printable_limit: 200)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Syncs the slug's objects missing from `slug_dir` into it, newest first,
  under a byte and time budget (see the moduledoc). Never raises; returns the
  counts for the caller to log.

  Options: `:config` (default the active one; nil does nothing),
  `:budget_bytes` (2 GiB), `:budget_ms` (5 minutes), `:max_object_bytes`
  (`Tarball.max_object_bytes/0`).
  """
  @spec prefetch(Path.t(), String.t(), keyword()) :: %{
          listed: non_neg_integer(),
          candidates: non_neg_integer(),
          downloaded: non_neg_integer(),
          discarded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          bytes: non_neg_integer(),
          list_failed: boolean()
        }
  def prefetch(slug_dir, slug, opts \\ []) do
    case Keyword.get_lazy(opts, :config, &active_config/0) do
      %Config{} = cfg -> Prefetch.run(cfg, slug_dir, slug, opts)
      _ -> Prefetch.empty_counts()
    end
  rescue
    e ->
      Logger.warning("Build cache L2 prefetch of #{slug} raised: #{Exception.message(e)}")
      %{Prefetch.empty_counts() | failed: 1}
  catch
    :exit, reason ->
      Logger.warning(
        "Build cache L2 prefetch of #{slug} exited: #{inspect(reason, printable_limit: 200)}"
      )

      %{Prefetch.empty_counts() | failed: 1}
  end

  @spec log_state() :: :ok
  def log_state do
    case Config.config() do
      {:ok, cfg} ->
        Logger.info(
          "Build cache L2 on: #{cfg.endpoint}/#{cfg.bucket}#{if cfg.read_only?, do: " (read-only)", else: ""}"
        )

      :off ->
        Logger.info("Build cache L2 off")

      {:error, msg} ->
        Logger.warning("Build cache L2 off: #{msg}")
    end

    :ok
  end
end
