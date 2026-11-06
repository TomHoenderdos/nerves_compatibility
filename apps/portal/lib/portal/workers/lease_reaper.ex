defmodule Portal.Workers.LeaseReaper do
  @moduledoc """
  Every five minutes (`:maintenance`, the web host): a `:leased` lease silent
  for 10 minutes or older than the job timeout plus 30 minutes, or an
  `:uploading` lease silent for 60 minutes, goes back to `:queued`; past
  `max_attempts` it is `:failed` and its request errored. Rows only, so any
  node could run it; the web host's queue keeps it off the build boxes.

  A `:queued` lease that has waited `stale_queued_minutes` (default 30,
  `config :portal, Portal.Workers.LeaseReaper`) while no builder able to
  claim it is around (`Portal.Builders.Routing.capable_builder?/1` for the
  lease's architectures) goes to a local build, as the admin's "requeue
  locally" does (`Portal.Builders.Leases.requeue_locally/2`). Routing only
  leases builds while such a builder is around, but that builder may go
  unready or silent afterwards, and `remote_mode: :on` leases regardless;
  nothing else would ever take those leases. One a ready builder could
  claim stays: it is a backlog, not an orphan. One tick looks at the
  oldest `stale_queued_limit` (default 100) such leases; the next takes the
  rest. The local build keeps the lease's scope (`Leases.requeue_locally/2`).

  A failed lease's upload dir is removed here, since nothing will ingest it.
  A requeued lease keeps its dir: the next attempt reuses the
  content-addressed files already uploaded.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Portal.Builders.{Lease, Leases, Routing, Upload}

  @default_stale_queued_minutes 30
  @default_stale_queued_limit 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{requeued: requeued, failed: failed, failed_ids: failed_ids} = Leases.reap()
    Enum.each(failed_ids, &Upload.cleanup/1)

    if requeued + failed > 0,
      do: Logger.info("Lease reaper: requeued #{requeued}, failed #{failed}")

    hand_back_orphans(DateTime.utc_now())
    :ok
  end

  defp hand_back_orphans(now) do
    for lease <- Leases.stale_queued(now, stale_queued_minutes(), stale_queued_limit()),
        not Routing.capable_builder?(arches(lease)) do
      case Leases.requeue_locally(lease) do
        {:ok, _job} ->
          Upload.cleanup(lease.id)

          Logger.warning(
            "Lease reaper: lease #{lease.id} (#{lease.package} #{lease.version}) waited " <>
              "#{stale_queued_minutes()} min with no builder able to claim it; requeued locally"
          )

        # Claimed or handed over in the meantime: nothing to do.
        {:error, reason} ->
          Logger.info("Lease reaper: lease #{lease.id} not requeued locally: #{inspect(reason)}")
      end
    end
  end

  # As `Leases.claim/2`: a lease without platform digests names one x86_64 image.
  defp arches(%Lease{args: %{"image_platforms" => %{} = platforms}}), do: Map.keys(platforms)
  defp arches(%Lease{}), do: ["x86_64"]

  defp stale_queued_minutes, do: config(:stale_queued_minutes, @default_stale_queued_minutes)
  defp stale_queued_limit, do: config(:stale_queued_limit, @default_stale_queued_limit)

  defp config(key, default) do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
