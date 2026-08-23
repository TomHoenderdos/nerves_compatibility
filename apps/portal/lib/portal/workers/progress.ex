defmodule Portal.Workers.Progress do
  @moduledoc """
  Shared `ScanRequest` bookkeeping for the two halves of the build pipeline.

  `Portal.Workers.Build` and `Portal.Workers.Ingest` are one user-visible
  operation split across two jobs, so they report the same way: write the status
  on the request row, then push the stage to whoever has the live request page
  open. Both are no-ops for builds that were started without a request behind
  them (admin backfills, catalog rebuilds).
  """

  require Logger

  alias Portal.ScanRequests

  @attempts 4
  @default_backoff_ms 500

  @doc """
  Write a terminal status onto the request row.

  Retries, because this is the last write of the pipeline and the only one with
  nothing behind it. The build ran, the rows are committed, and the Oban job is
  about to be marked complete; if this write is lost the request sits in a
  non-terminal status for good, and `open_request_for_package/1` then matches
  that dead row and swallows every later request for the same package. A
  transient pool timeout was enough to do it. Still returns `:ok` when every
  attempt fails: failing the job here would re-run an ingest that already
  committed its run.
  """
  @spec mark(String.t() | nil, atom(), keyword()) :: :ok
  def mark(id, status, opts \\ [])

  def mark(nil, _status, _opts), do: :ok

  def mark(id, status, opts) when is_binary(id), do: mark_with_retry(id, status, opts, 1)

  defp mark_with_retry(id, status, opts, attempt) do
    case ScanRequests.set_status(id, status, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @attempts ->
        Logger.warning(
          "Failed to mark request #{id} #{status} " <>
            "(attempt #{attempt}/#{@attempts}), retrying: #{inspect(reason)}"
        )

        Process.sleep(backoff_ms() * 2 ** (attempt - 1))
        mark_with_retry(id, status, opts, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "Gave up marking request #{id} #{status} after #{@attempts} attempts; " <>
            "the row is now stranded in a non-terminal status: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp backoff_ms do
    Application.get_env(:portal, :progress_mark_backoff_ms, @default_backoff_ms)
  end

  @spec broadcast(String.t() | nil, atom(), map()) :: :ok
  def broadcast(nil, _stage, _payload), do: :ok

  def broadcast(scan_request_id, stage, payload) when is_binary(scan_request_id) do
    Phoenix.PubSub.broadcast(
      Portal.PubSub,
      "request:#{scan_request_id}",
      {:build_progress, stage, payload}
    )

    :ok
  end
end
