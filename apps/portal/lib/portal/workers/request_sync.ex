defmodule Portal.Workers.RequestSync do
  @moduledoc """
  Oban worker (queue `:maintenance`) that keeps `portal_scan_requests` in step
  with the jobs doing the work.

  A request and its jobs live in two tables, and only the workers move a request
  along. Anything that stops a job without running it -- cancelling in Oban
  Web, discarding after the last attempt -- leaves the request `queued`
  forever. A cancelled 5k sweep left 3,417 of them in the admin queue on
  2026-10-11, and an open request also blocks the next one for its package:
  `Portal.ScanRequests.create_once/1` hands back the dead request instead of
  queueing a build.

  Two rules:

    * **Open requests with no live Build, RemoteBuild or Ingest job and no
      open `builder_leases` row** are closed. Ours
      (`backfill`, `catalog_seed`, `update_check`) are deleted; nobody asked
      for them. A person's request is kept and closed as an `error` so they
      can see what happened. Requests younger than ten
      minutes are skipped: `create_once/1` inserts the request before its job,
      and a sync between the two would take it for an orphan.

    * **Our own finished requests** are deleted a day after they finish. The
      package page shows a request's outcome until then; after that the run
      is the record. A run that pointed at one keeps its row, with the link
      cleared.

  A person's request is never deleted.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Portal.AdminEvents
  alias Portal.Repo

  @system_sources ~w(backfill catalog_seed update_check)
  @live_states ~w(available scheduled executing retryable)
  @job_workers ~w(Portal.Workers.Build Portal.Workers.RemoteBuild Portal.Workers.Ingest)
  # A remote build's `RemoteBuild` job completes once it has written the
  # lease, so from then until the builder completes the lease is the only
  # live work. `done` does not count: the builder's `complete` commits the
  # `done` transition and the `Ingest` insert together, so the live Ingest
  # job covers the request from there, and a `done` lease whose Ingest died
  # must not hold its request open for good.
  @open_lease_states ~w(queued leased uploading)
  @retain_finished_hours 24
  @grace_minutes 10

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = NaiveDateTime.utc_now()
    grace_cutoff = NaiveDateTime.add(now, -@grace_minutes * 60)
    finished_cutoff = NaiveDateTime.add(now, -@retain_finished_hours * 3600)

    {deleted_orphans, closed_orphans} = close_orphans(grace_cutoff)
    deleted_finished = delete_finished(finished_cutoff)

    if deleted_orphans + closed_orphans + deleted_finished > 0 do
      Logger.info(
        "Request sync: deleted #{deleted_orphans} orphaned and #{deleted_finished} " <>
          "finished system requests, closed #{closed_orphans} orphaned user requests"
      )
    end

    :ok
  end

  defp close_orphans(cutoff) do
    orphans =
      from(r in "portal_scan_requests",
        as: :request,
        where: r.status in ["accepted", "queued"],
        where: r.inserted_at < ^cutoff,
        where:
          not exists(
            from(j in "oban_jobs",
              where: j.worker in ^@job_workers,
              where: j.state in ^@live_states,
              where:
                fragment("? ->> 'scan_request_id'", j.args) ==
                  fragment("?::text", parent_as(:request).id),
              select: 1
            )
          ),
        where:
          not exists(
            from(l in "builder_leases",
              where: l.state in ^@open_lease_states,
              where: l.scan_request_id == parent_as(:request).id,
              select: 1
            )
          )
      )

    {deleted, _} =
      orphans |> where([r], r.source in ^@system_sources) |> Repo.delete_all()

    announce_if_changed(deleted)

    {closed, _} =
      orphans
      |> where([r], r.source not in ^@system_sources)
      |> Repo.update_all(
        set: [
          status: "error",
          error_reason: "build job cancelled",
          updated_at: NaiveDateTime.utc_now()
        ]
      )

    announce_if_changed(closed)

    {deleted, closed}
  end

  defp delete_finished(cutoff) do
    finished =
      from(r in "portal_scan_requests",
        where: r.source in ^@system_sources,
        where: r.status in ["built", "rejected", "error"],
        where: r.updated_at < ^cutoff,
        select: r.id
      )

    Repo.transaction(fn ->
      Repo.update_all(
        from(run in "catalog_runs", where: run.scan_request_id in subquery(finished)),
        set: [scan_request_id: nil]
      )

      {deleted, _} =
        Repo.delete_all(from(r in "portal_scan_requests", where: r.id in subquery(finished)))

      deleted
    end)
    |> case do
      {:ok, deleted} ->
        announce_if_changed(deleted)
        deleted
    end
  end

  # A sync that touched nothing has nothing to tell an open admin queue page;
  # one that did announces it once per write, which `AdminEvents.throttle/3`
  # collapses on the reading side when several land in the same tick.
  defp announce_if_changed(0), do: :ok
  defp announce_if_changed(_count), do: AdminEvents.broadcast(:queue)
end
