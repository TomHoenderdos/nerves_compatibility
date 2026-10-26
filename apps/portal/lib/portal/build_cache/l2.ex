defmodule Portal.BuildCache.L2 do
  @moduledoc """
  The second, shared layer of the dependency build cache: an S3 bucket
  every home build host reads before a build and writes after a promotion.
  (Full moduledoc in Task 7: what is fetched and why it is trusted; see the
  spec, sections 3.1 and 5.)
  """
  require Logger
  alias Portal.BuildCache.L2.{Config, Stats}

  @spec object_key(String.t(), String.t()) :: String.t()
  def object_key(slug, key), do: slug <> "/" <> key <> ".tar.gz"

  @doc "On only with a complete config and a local cache to restore into."
  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _}, Config.config()) and Portal.Builder.build_cache() != nil

  @spec status() :: map()
  def status do
    base = %{
      node: Portal.BuildCache.Staging.host(),
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
