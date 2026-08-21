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

  @spec mark(String.t() | nil, atom(), keyword()) :: :ok
  def mark(id, status, opts \\ [])

  def mark(nil, _status, _opts), do: :ok

  def mark(id, status, opts) when is_binary(id) do
    case ScanRequests.set_status(id, status, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark request #{id} #{status}: #{inspect(reason)}")
        :ok
    end
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
