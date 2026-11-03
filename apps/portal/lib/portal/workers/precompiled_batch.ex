defmodule Portal.Workers.PrecompiledBatch do
  @moduledoc """
  Every 15 minutes, sign a batch naming every package's precompiled manifest
  bytes, rendering only the packages whose inputs changed since the last batch
  (`Portal.Precompiled.Batches`). The job must finish inside its slot: the
  uniqueness below skips a cron insert while the previous job is still
  executing, which is how a ~15-minute render of every package made the
  cadence 30 minutes. Runs on `:maintenance`, which only the web host serves:
  the signing key and the rsynced artifact files live there. Without a key
  configured the job cancels; builders never sign. A key that is configured
  but unreadable (wrong owner, bad path) errors instead, so Oban retries and
  the failure is visible rather than cancelling quietly.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger
  alias Portal.Precompiled.Batches

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Batches.build_and_sign() do
      {:ok, batch} ->
        Logger.info(
          "precompiled batch #{batch.sequence} signed, #{batch.manifest_count} manifests"
        )

        :ok

      {:error, :no_signing_key} ->
        {:cancel, :no_signing_key}

      {:error, :signing_key_unreadable} ->
        {:error, :signing_key_unreadable}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
