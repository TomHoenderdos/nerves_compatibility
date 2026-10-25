defmodule Portal.Workers.LeaseReaper do
  @moduledoc """
  Every five minutes (`:maintenance`, the web host): a `:leased` lease silent
  for 10 minutes or older than the job timeout plus 30 minutes, or an
  `:uploading` lease silent for 60 minutes, goes back to `:queued`; past
  `max_attempts` it is `:failed` and its request errored. Rows only, so any
  node could run it; the web host's queue keeps it off the build boxes.

  A failed lease's upload dir is removed here, since nothing will ingest it.
  A requeued lease keeps its dir: the next attempt reuses the
  content-addressed files already uploaded.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Portal.Builders.{Leases, Upload}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{requeued: requeued, failed: failed, failed_ids: failed_ids} = Leases.reap()
    Enum.each(failed_ids, &Upload.cleanup/1)

    if requeued + failed > 0,
      do: Logger.info("Lease reaper: requeued #{requeued}, failed #{failed}")

    :ok
  end
end
