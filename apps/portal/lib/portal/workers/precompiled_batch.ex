defmodule Portal.Workers.PrecompiledBatch do
  @moduledoc """
  Every 15 minutes, render every precompiled manifest to bytes and sign a
  batch naming them. Runs on `:maintenance`, which only the web host serves:
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
