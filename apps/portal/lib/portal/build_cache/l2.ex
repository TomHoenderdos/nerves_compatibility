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

  Only content-addressed slugs are shared (`shareable_slug?/1`):
  `sha256_<64 hex>`, not the all-zero digest. Anything else (`unknown`, a
  tag, a truncated digest) names no particular image, so two hosts could
  mean different images by it; such a slug is neither uploaded nor
  prefetched.

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

  The budget is per build: at most 2 GiB downloaded, 4 GiB extracted and 5
  minutes (listing, downloads and extraction all count), and no single
  object over `Tarball.max_object_bytes/0`. An object over the remaining
  byte budget is skipped rather than ending the loop, so small entries
  behind a large one still arrive. A timeout or a transport error ends the
  loop for this build: the store is unwell, and the build should not wait on
  it once per object. So does free space on the cache filesystem below
  `Portal.Builder.prefetch_min_free_bytes/0`, checked before every object.
  Two builds on one node never fetch the same key at once (`Stats.claim/1`).

  Uploads run before Ingest is enqueued, so they are bounded too: each PUT
  in total time (send included), and all of one promotion's uploads by one
  deadline (`Portal.BuildCache.Promotion.l2_upload_budget_ms/0`).

  ## Why a downloaded entry is trusted

  A local entry is trusted because Promotion checked it: the key recomputed,
  the outer checksum matched Hex, the tree walked on a host-private copy.
  The downloader cannot repeat any of that; it did not build the tree and
  cannot recompute its key. It trusts the bucket instead, and the bucket is
  trustworthy exactly as far as its writers are: only hosts holding the
  read-write key can PUT, and each of them runs Promotion before uploading.
  The integrity of L2 is the integrity of that key (`docs/BUILD_CACHE_L2.md`:
  read-write on the home hosts only, read-only for anything else).

  What the downloader still checks is what a faulty transport could change.
  The tarball's SHA-256 must equal the uploader's metadata, and the object
  may not be larger than the listing said. The SHA-256 travels in the same
  response as the body, so it detects corruption, not tampering: over plain
  `http` anyone on the path can replace both. That is acceptable only on the
  tailnet, which encrypts the path; any other endpoint must be `https`
  (`Config.insecure_endpoint?/1`, warned about at boot by `log_state/0`).
  Whatever arrives, `Tarball.unpack/3` bounds what inflating it may cost,
  screens the tar table before extracting anything (regular files and
  directories only, safe names, bounded size), recreates
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

  @shareable_slug ~r/\Asha256_[0-9a-f]{64}\z/
  @zero_slug "sha256_" <> String.duplicate("0", 64)

  @doc "Whether `slug` names one image by content: `sha256_<64 hex>`, not all zeros."
  @spec shareable_slug?(term()) :: boolean()
  def shareable_slug?(slug) when is_binary(slug),
    do: slug != @zero_slug and Regex.match?(@shareable_slug, slug)

  def shareable_slug?(_slug), do: false

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
  size, `:skipped` when L2 is off or read-only or the slug is not shareable,
  `{:error, reason}` on any failure, never an exception or exit. Logs its own
  outcome and records it in `Stats`. Options: `:config` (default the active
  one) and `:timeout_ms`, the PUT's total time (default 120 s).
  """
  @spec upload(Path.t(), String.t(), String.t(), String.t() | :any, keyword()) ::
          {:ok, non_neg_integer()} | :skipped | {:error, term()}
  def upload(entry_dir, slug, key, package, opts \\ []) do
    case Keyword.get_lazy(opts, :config, &active_config/0) do
      %Config{read_only?: false} = cfg ->
        if shareable_slug?(slug) do
          do_upload(cfg, entry_dir, slug, key, package, opts)
        else
          Logger.info(
            "Build cache L2 upload of #{key} skipped: slug #{show(slug)} is not shareable"
          )

          :skipped
        end

      _ ->
        :skipped
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp show(term), do: inspect(term, printable_limit: 100)

  defp active_config do
    case Config.config() do
      {:ok, cfg} -> cfg
      _ -> nil
    end
  end

  # `entry_dir` is a promoted entry under the operator's cache root; the
  # tarball is staged beside it, inside the slug dir, and always removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_upload(cfg, entry_dir, slug, key, package, opts) do
    object = object_key(slug, key)
    tar = Staging.name(entry_dir) <> ".tar.gz"

    result =
      try do
        with {:ok, %{sha256: sha, bytes: bytes}} <- Tarball.pack(entry_dir, tar, package),
             :ok <- Client.put(cfg, object, tar, sha, Keyword.take(opts, [:timeout_ms])) do
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
  `:budget_bytes` (2 GiB downloaded), `:extracted_budget_bytes` (4 GiB
  extracted), `:budget_ms` (5 minutes), `:max_object_bytes`
  (`Tarball.max_object_bytes/0`), `:free_bytes` (a `fn dir -> bytes | nil`,
  default `Portal.Builder.free_bytes/1`) and `:min_free_bytes` (default
  `Portal.Builder.prefetch_min_free_bytes/0`).
  """
  @spec prefetch(Path.t(), String.t(), keyword()) :: %{
          listed: non_neg_integer(),
          candidates: non_neg_integer(),
          downloaded: non_neg_integer(),
          discarded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          bytes: non_neg_integer(),
          extracted_bytes: non_neg_integer(),
          list_failed: boolean()
        }
  def prefetch(slug_dir, slug, opts \\ []) do
    case Keyword.get_lazy(opts, :config, &active_config/0) do
      %Config{} = cfg ->
        if shareable_slug?(slug) do
          Prefetch.run(cfg, slug_dir, slug, opts)
        else
          Logger.info("Build cache L2 prefetch skipped: slug #{show(slug)} is not shareable")
          Prefetch.empty_counts()
        end

      _ ->
        Prefetch.empty_counts()
    end
  rescue
    e ->
      Logger.warning("Build cache L2 prefetch of #{show(slug)} raised: #{Exception.message(e)}")
      %{Prefetch.empty_counts() | failed: 1}
  catch
    kind, reason ->
      Logger.warning(
        "Build cache L2 prefetch of #{show(slug)} failed: #{inspect({kind, reason}, printable_limit: 200)}"
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

        if Config.insecure_endpoint?(cfg) do
          Logger.warning(
            "Build cache L2 endpoint #{cfg.endpoint} is plain http outside the tailnet; " <>
              "entries can be tampered with in transit"
          )
        end

      :off ->
        Logger.info("Build cache L2 off")

      {:error, msg} ->
        Logger.warning("Build cache L2 off: #{msg}")
    end

    :ok
  end
end
