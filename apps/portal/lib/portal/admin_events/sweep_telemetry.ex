defmodule Portal.AdminEvents.SweepTelemetry do
  @moduledoc """
  Tells the Maintenance page when an Oban job belonging to a bulk rebuild
  sweep finishes, so its live counts (`Portal.BulkRebuild.status/1`) can
  refresh without polling.

  Attached to `[:oban, :job, :stop]` and `[:oban, :job, :exception]` rather
  than called from inside `Portal.Workers.Build` or `Portal.Workers.Ingest`:
  those events fire from `Oban.Queue.Executor.report_finished/1` only after
  `ack_event/1` has already recorded the attempt's new state (completed,
  retryable, discarded or cancelled). A broadcast from inside a worker's own
  `perform/1` fired before that ack, so the Maintenance page could reload
  `Portal.BulkRebuild.status/1` on the broadcast and still see the job
  `executing`. Attaching here instead means every reload the broadcast
  triggers sees the state Oban already recorded for it. It also reaches
  `Portal.Workers.Backfill` (a sweep's intake step) for free, with no extra
  code in any of the three workers.

  Two meta keys are watched, deliberately not the same one:

    * `"sweep_id"` -- set on the `Portal.Workers.Backfill` and
      `Portal.Workers.Build` jobs a sweep queues directly
      (`Portal.BulkRebuild.job/7`, `Portal.ScanRequests.insert_build_job/4`).
      This is also the key `Portal.BulkRebuild.sweep_jobs/1` filters
      `status/1` and `cancel/1` on.
    * `"announce_sweep"` -- set on the `Portal.Workers.Ingest` job a sweep's
      build hands off to (`Portal.Workers.Build.enqueue_ingest/4`). It is a
      different key on purpose: `sweep_jobs/1` matches any worker's meta by
      JSONB containment, so an Ingest job tagged `sweep_id` would fall inside
      `cancel/1`'s scope -- cancelling a pending ingest loses a finished
      build's result and leaks its scratch dir -- and would be double-counted
      by `status/1`. `announce_sweep` reaches only this handler.

  A job with neither key never broadcasts.
  """

  require Logger

  @events [[:oban, :job, :stop], [:oban, :job, :exception]]

  @doc "Attaches the handler. Safe to call more than once; re-attaching detaches first."
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(__MODULE__)
    :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)
    :ok
  end

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    case metadata do
      %{job: %Oban.Job{meta: meta}} ->
        if meta["sweep_id"] || meta["announce_sweep"] do
          Portal.AdminEvents.broadcast(:sweeps)
        end

      _other ->
        :ok
    end

    :ok
  rescue
    exception ->
      # :telemetry detaches a handler that raises, which would silence every
      # future sweep broadcast for the life of the node. Whatever goes wrong
      # here is logged and swallowed instead, same as
      # `Portal.AdminEvents.broadcast/1`'s own rescue of a PubSub failure.
      Logger.warning("sweep telemetry handler failed: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("sweep telemetry handler failed: #{kind} #{inspect(reason)}")
      :ok
  end
end
