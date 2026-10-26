defmodule Portal.BuildCache.L2 do
  @moduledoc """
  The second, shared layer of the dependency build cache: an S3 bucket
  every home build host reads before a build and writes after a promotion.
  (Full moduledoc in Task 7: what is fetched and why it is trusted; see the
  spec, sections 3.1 and 5.)
  """
  require Logger
  alias Portal.BuildCache.L2.{Client, Config, Stats, Tarball}
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
